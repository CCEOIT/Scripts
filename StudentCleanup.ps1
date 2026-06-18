#Requires -RunAsAdministrator
# CenterState CEO - Surface Go 2 Student Cleanup Script
# Run as P2A (local admin) between student sessions.
# Clears browsing data, resets Chrome/Edge, wipes user folders,
# cleans the desktop, and disconnects any Microsoft account tied to P2A.

[CmdletBinding()]
param(
    [string]$TargetUser = 'P2A'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$LogFile = "C:\Scripts\StudentCleanup_$(Get-Date -f 'yyyyMMdd_HHmmss').log"
if (-not (Test-Path 'C:\Scripts')) { New-Item -ItemType Directory -Path 'C:\Scripts' | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -f 'HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}

function Stop-AppIfRunning {
    param([string[]]$Names)
    foreach ($name in $Names) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------------------
# Resolve the target user's profile path
# ---------------------------------------------------------------------------
$userProfile = "C:\Users\$TargetUser"
if (-not (Test-Path $userProfile)) {
    Write-Log "Profile path $userProfile not found. Exiting." 'ERROR'
    exit 1
}

Write-Log "=== Student Cleanup Starting for user: $TargetUser ==="

# ===========================================================================
# 1. SIGN OUT OF ONEDRIVE
# ===========================================================================
Write-Log "--- Signing out of OneDrive ---"

$oneDrivePaths = @(
    "$userProfile\AppData\Local\Microsoft\OneDrive\OneDrive.exe",
    "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
    "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe"
)

Stop-AppIfRunning 'OneDrive'
# Note: OneDrive cannot be launched as Administrator, so we skip /signout
# and rely entirely on wiping its settings and credentials below.

# Wipe OneDrive sync settings so it can't auto-reconnect
$oneDriveSettingsPaths = @(
    "$userProfile\AppData\Local\Microsoft\OneDrive\settings",
    "$userProfile\AppData\Local\Microsoft\OneDrive\logs"
)
foreach ($p in $oneDriveSettingsPaths) {
    if (Test-Path $p) {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed OneDrive folder: $p"
    }
}

# ===========================================================================
# 2. SIGN OUT OF MICROSOFT 365 APPS (Office, Teams, etc.)
# ===========================================================================
Write-Log "--- Clearing Microsoft 365 / Office credentials ---"

Stop-AppIfRunning 'Teams','ms-teams','Outlook','OUTLOOK','WINWORD','EXCEL','POWERPNT','ONENOTE','MSACCESS','lync'

# Office identity registry keys (applies to Office 2016 / 2019 / M365)
$officeIdentityPaths = @(
    "HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities",
    "HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Profiles",
    "HKCU:\Software\Microsoft\Office\16.0\Common\Internet\WebServiceCache",
    "HKCU:\Software\Microsoft\Office\16.0\Common\ServicesManagerCache",
    "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles",
    "HKCU:\Software\Microsoft\Office\15.0\Common\Identity\Identities",
    "HKCU:\Software\Microsoft\Office\15.0\Common\Identity\Profiles"
)
foreach ($regPath in $officeIdentityPaths) {
    if (Test-Path $regPath) {
        Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared registry: $regPath"
    }
}

# Remove Office token cache files
$officeCacheDir = "$userProfile\AppData\Local\Microsoft\Office\16.0\Wef"
if (Test-Path $officeCacheDir) {
    Remove-Item $officeCacheDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Cleared Office WEF cache"
}

# Clear Teams local app data (classic Teams)
$teamsPaths = @(
    "$userProfile\AppData\Roaming\Microsoft\Teams",
    "$userProfile\AppData\Local\Microsoft\Teams",
    "$userProfile\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache"
)
foreach ($tp in $teamsPaths) {
    if (Test-Path $tp) {
        Remove-Item $tp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared Teams data: $tp"
    }
}

# ===========================================================================
# 3. DISCONNECT MICROSOFT ACCOUNT FROM LOCAL P2A WINDOWS ACCOUNT
# ===========================================================================
Write-Log "--- Removing Microsoft account association from local P2A account ---"

# Remove all Microsoft account entries from Windows Credential Manager
Write-Log "Scanning Credential Manager for Microsoft account entries..."
$credOutput = cmdkey /list 2>&1
$credLines  = $credOutput | Select-String -Pattern 'Target:' | ForEach-Object { $_.Line.Trim() }

foreach ($line in $credLines) {
    $target = ($line -replace 'Target:\s*', '').Trim()
    if ($target -match 'MicrosoftOffice|MicrosoftAccount|microsoft\.com|live\.com|outlook\.com|office365|sharepoint|OneDrive') {
        cmdkey /delete:"$target" 2>&1 | Out-Null
        Write-Log "Removed credential: $target"
    }
}

# Remove Windows Live / MSA tokens from registry
$msaRegPaths = @(
    "HKCU:\Software\Microsoft\IdentityStore",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\SessionData",
    "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin",
    "HKCU:\Software\Microsoft\Accounts"
)
foreach ($regPath in $msaRegPaths) {
    if (Test-Path $regPath) {
        Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared MSA registry path: $regPath"
    }
}

# Remove the "connected account" link stored under the profile SID
# This is what ties a Microsoft account to a local Windows login
try {
    $userSID = (Get-LocalUser -Name $TargetUser).SID.Value
    $connectedAccountKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$userSID"
    if (Test-Path $connectedAccountKey) {
        $connProp = Get-ItemProperty $connectedAccountKey -Name 'ConnectedIdentity' -ErrorAction SilentlyContinue
        if ($connProp) {
            Remove-ItemProperty $connectedAccountKey -Name 'ConnectedIdentity' -Force -ErrorAction SilentlyContinue
            Write-Log "Removed ConnectedIdentity from profile registry for SID $userSID"
        } else {
            Write-Log "No ConnectedIdentity found in profile registry (already local-only)."
        }
    }
} catch {
    Write-Log "Could not query local user SID: $_" 'WARN'
}

# Remove Azure AD / work-school account join artifacts (dsregcmd)
$dsregStatus = dsregcmd /status 2>&1
if ($dsregStatus -match 'WorkplaceJoined\s*:\s*YES') {
    Write-Log "Workplace-joined device detected - running dsregcmd /leave"
    dsregcmd /leave 2>&1 | Out-Null
}

# ===========================================================================
# 4. RESET GOOGLE CHROME (clear all browsing data, reset to defaults)
# ===========================================================================
Write-Log "--- Resetting Google Chrome ---"

Stop-AppIfRunning 'chrome'

$chromeUserData = "$userProfile\AppData\Local\Google\Chrome\User Data"
if (Test-Path $chromeUserData) {
    # Items to delete inside the Default profile (history, cache, cookies, saved passwords, etc.)
    $chromeProfileItems = @(
        'Default\History',
        'Default\History-journal',
        'Default\Cookies',
        'Default\Cookies-journal',
        'Default\Cache',
        'Default\Code Cache',
        'Default\GPUCache',
        'Default\Login Data',
        'Default\Login Data For Account',
        'Default\Login Data-journal',
        'Default\Web Data',
        'Default\Web Data-journal',
        'Default\Favicons',
        'Default\Media History',
        'Default\Network Action Predictor',
        'Default\Visited Links',
        'Default\Top Sites',
        'Default\Shortcuts',
        'Default\Last Session',
        'Default\Last Tabs',
        'Default\Current Session',
        'Default\Current Tabs',
        'Default\Session Storage',
        'Default\Local Storage',
        'Default\IndexedDB',
        'Default\databases',
        'Default\Extension State',
        'Default\Service Worker',
        'Default\File System',
        'Default\Platform Notifications',
        'Default\Download Metadata',
        'Default\Affiliation Database',
        'Default\Sync Data',
        'Default\Sync Extension Settings',
        'Default\Extension Cookies',
        'Default\Autofill',
        'Default\BudgetDatabase',
        'Default\shared_proto_db',
        'GrShaderCache',
        'ShaderCache',
        'Crashpad'
    )
    foreach ($item in $chromeProfileItems) {
        $fullPath = Join-Path $chromeUserData $item
        if (Test-Path $fullPath) {
            Remove-Item $fullPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Chrome: removed $item"
        }
    }

    # Reset Chrome preferences to defaults (clears extensions, settings, homepage)
    $chromePrefFile = Join-Path $chromeUserData 'Default\Preferences'
    if (Test-Path $chromePrefFile) {
        Remove-Item $chromePrefFile -Force -ErrorAction SilentlyContinue
        Write-Log "Chrome: removed Preferences (will regenerate as default on next launch)"
    }
    $chromeSecurePrefFile = Join-Path $chromeUserData 'Default\Secure Preferences'
    if (Test-Path $chromeSecurePrefFile) {
        Remove-Item $chromeSecurePrefFile -Force -ErrorAction SilentlyContinue
    }

    # Remove any signed-in Google accounts
    $chromeLocalState = Join-Path $chromeUserData 'Local State'
    if (Test-Path $chromeLocalState) {
        try {
            $state = Get-Content $chromeLocalState -Raw | ConvertFrom-Json
            if ($state.profile.info_cache) {
                $state.profile.info_cache = [PSCustomObject]@{}
            }
            if ($state.profile.last_used) { $state.profile.last_used = 'Default' }
            $state | ConvertTo-Json -Depth 20 | Set-Content $chromeLocalState -Encoding UTF8
            Write-Log "Chrome: cleared account list from Local State"
        } catch {
            Write-Log "Chrome: could not modify Local State (non-fatal): $_" 'WARN'
        }
    }
} else {
    Write-Log "Chrome user data not found at $chromeUserData - skipping."
}

# ===========================================================================
# 5. RESET MICROSOFT EDGE (clear all browsing data, reset to defaults)
# ===========================================================================
Write-Log "--- Resetting Microsoft Edge ---"

Stop-AppIfRunning 'msedge','MicrosoftEdge'

$edgeUserData = "$userProfile\AppData\Local\Microsoft\Edge\User Data"
if (Test-Path $edgeUserData) {
    $edgeProfileItems = @(
        'Default\History',
        'Default\History-journal',
        'Default\Cookies',
        'Default\Cookies-journal',
        'Default\Cache',
        'Default\Code Cache',
        'Default\GPUCache',
        'Default\Login Data',
        'Default\Login Data For Account',
        'Default\Login Data-journal',
        'Default\Web Data',
        'Default\Web Data-journal',
        'Default\Favicons',
        'Default\Media History',
        'Default\Network Action Predictor',
        'Default\Visited Links',
        'Default\Top Sites',
        'Default\Shortcuts',
        'Default\Last Session',
        'Default\Last Tabs',
        'Default\Current Session',
        'Default\Current Tabs',
        'Default\Session Storage',
        'Default\Local Storage',
        'Default\IndexedDB',
        'Default\databases',
        'Default\Extension State',
        'Default\Service Worker',
        'Default\File System',
        'Default\Platform Notifications',
        'Default\Download Metadata',
        'Default\Collections',
        'Default\Sync Data',
        'Default\Autofill',
        'Default\shared_proto_db',
        'GrShaderCache',
        'ShaderCache',
        'Crashpad'
    )
    foreach ($item in $edgeProfileItems) {
        $fullPath = Join-Path $edgeUserData $item
        if (Test-Path $fullPath) {
            Remove-Item $fullPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Edge: removed $item"
        }
    }

    # Reset Edge preferences
    $edgePrefFile = Join-Path $edgeUserData 'Default\Preferences'
    if (Test-Path $edgePrefFile) {
        Remove-Item $edgePrefFile -Force -ErrorAction SilentlyContinue
        Write-Log "Edge: removed Preferences"
    }
    $edgeSecurePrefFile = Join-Path $edgeUserData 'Default\Secure Preferences'
    if (Test-Path $edgeSecurePrefFile) {
        Remove-Item $edgeSecurePrefFile -Force -ErrorAction SilentlyContinue
    }

    # Clear Edge account/profile info from Local State
    $edgeLocalState = Join-Path $edgeUserData 'Local State'
    if (Test-Path $edgeLocalState) {
        try {
            $state = Get-Content $edgeLocalState -Raw | ConvertFrom-Json
            if ($state.profile.info_cache) {
                $state.profile.info_cache = [PSCustomObject]@{}
            }
            if ($state.profile.last_used) { $state.profile.last_used = 'Default' }
            $state | ConvertTo-Json -Depth 20 | Set-Content $edgeLocalState -Encoding UTF8
            Write-Log "Edge: cleared account list from Local State"
        } catch {
            Write-Log "Edge: could not modify Local State (non-fatal): $_" 'WARN'
        }
    }
} else {
    Write-Log "Edge user data not found at $edgeUserData - skipping."
}

# ===========================================================================
# 6. CLEAN THE DESKTOP
# Keep: Google Chrome shortcut, Microsoft Edge shortcut, Recycle Bin
# ===========================================================================
Write-Log "--- Cleaning Desktop ---"

# Shortcuts to preserve (by partial name, case-insensitive)
$keepPatterns = @('Google Chrome', 'Microsoft Edge', 'desktop.ini')

$desktopPaths = @(
    "$userProfile\Desktop",
    'C:\Users\Public\Desktop'
)

foreach ($desktopPath in $desktopPaths) {
    if (-not (Test-Path $desktopPath)) { continue }
    Get-ChildItem $desktopPath -Force | Where-Object {
        $name = $_.Name
        # Keep the item if it matches any keep pattern
        $keep = $false
        foreach ($pattern in $keepPatterns) {
            if ($name -like "*$pattern*") { $keep = $true; break }
        }
        -not $keep
    } | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Desktop: removed $($_.Name)"
    }
}

# ===========================================================================
# 7. WIPE USER DATA FOLDERS
# ===========================================================================
Write-Log "--- Wiping user data folders ---"

$foldersToWipe = @(
    "$userProfile\Documents",
    "$userProfile\Downloads",
    "$userProfile\Videos",
    "$userProfile\Pictures",
    "$userProfile\Music",
    "$userProfile\AppData\Local\Temp"
)

foreach ($folder in $foldersToWipe) {
    if (Test-Path $folder) {
        Get-ChildItem $folder -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "Wiped contents of: $folder"
    }
}

# Empty the Recycle Bin
try {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Log "Recycle Bin emptied."
} catch {
    Write-Log "Could not empty Recycle Bin (non-fatal): $_" 'WARN'
}

# ===========================================================================
# 8. CLEAR WINDOWS EXPLORER RECENT FILES / QUICK ACCESS HISTORY
# ===========================================================================
Write-Log "--- Clearing recent files and Quick Access history ---"

$recentPaths = @(
    "$userProfile\AppData\Roaming\Microsoft\Windows\Recent",
    "$userProfile\AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations",
    "$userProfile\AppData\Roaming\Microsoft\Windows\Recent\CustomDestinations"
)
foreach ($p in $recentPaths) {
    if (Test-Path $p) {
        Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared: $p"
    }
}

# ===========================================================================
# 9. WIFI - FORGET ALL NETWORKS EXCEPT "ONRAMP - Pathways", ENSURE AUTO-CONNECT
# ===========================================================================
Write-Log "--- Configuring WiFi ---"

$targetSSID = 'ONRAMP - Pathways'

# Get all saved wireless profiles
$allProfiles = (netsh wlan show profiles) -match '^\s*All User Profile\s*:' |
    ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() }

Write-Log "Found WiFi profiles: $($allProfiles -join ', ')"

foreach ($profile in $allProfiles) {
    if ($profile -like $targetSSID) {
        Write-Log "Keeping WiFi profile: $profile"
    } else {
        netsh wlan delete profile name="$profile" | Out-Null
        Write-Log "Forgot WiFi network: $profile"
    }
}

# Verify the target profile still exists
$profileCheck = (netsh wlan show profiles) -match '^\s*All User Profile\s*:' |
    ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() } |
    Where-Object { $_ -like $targetSSID }
if ($profileCheck) {
    # Enable auto-connect on the target SSID
    netsh wlan set profileparameter name="$targetSSID" connectionmode=auto | Out-Null
    Write-Log "Auto-connect enabled for: $targetSSID"

    # Connect if not already connected
    $currentSSID = (netsh wlan show interfaces) -match '^\s*SSID\s*:' |
        Where-Object { $_ -notmatch 'BSSID' } |
        ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() } |
        Select-Object -First 1

    if ($currentSSID -ne $targetSSID) {
        netsh wlan connect name="$targetSSID" | Out-Null
        Write-Log "Connecting to: $targetSSID"
    } else {
        Write-Log "Already connected to: $targetSSID"
    }
} else {
    Write-Log "WARNING: Profile '$targetSSID' not found -- device may need manual WiFi setup." 'WARN'
}

# ===========================================================================
# 10. RESTORE CHROME AND EDGE DESKTOP SHORTCUTS
# Run last so nothing can remove them after this point.
# ===========================================================================
Write-Log "--- Restoring Chrome and Edge desktop shortcuts ---"

$wsh = New-Object -ComObject WScript.Shell

$chromeShortcut = "$userProfile\Desktop\Google Chrome.lnk"
$chromeBin      = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (-not (Test-Path $chromeShortcut)) {
    if (Test-Path $chromeBin) {
        $s = $wsh.CreateShortcut($chromeShortcut)
        $s.TargetPath       = $chromeBin
        $s.Description      = 'Google Chrome'
        $s.Save()
        Write-Log "Created Chrome shortcut on Desktop"
    } else {
        Write-Log "Chrome executable not found at $chromeBin - shortcut not created" 'WARN'
    }
} else {
    Write-Log "Chrome shortcut already present"
}

$edgeShortcut = "$userProfile\Desktop\Microsoft Edge.lnk"
$edgeBin      = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edgeShortcut)) {
    if (Test-Path $edgeBin) {
        $s = $wsh.CreateShortcut($edgeShortcut)
        $s.TargetPath       = $edgeBin
        $s.Description      = 'Microsoft Edge'
        $s.Save()
        Write-Log "Created Edge shortcut on Desktop"
    } else {
        Write-Log "Edge executable not found at $edgeBin - shortcut not created" 'WARN'
    }
} else {
    Write-Log "Edge shortcut already present"
}

# ===========================================================================
# Done
# ===========================================================================
Write-Log "=== Student Cleanup Complete ==="
Write-Log "Log saved to: $LogFile"
Write-Host ""
Write-Host "IMPORTANT: A reboot is recommended to fully apply account changes." -ForegroundColor Yellow
Write-Host "Log file: C:\Scripts\$( Split-Path $LogFile -Leaf )" -ForegroundColor Cyan
