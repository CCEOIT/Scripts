#Requires -RunAsAdministrator
# CenterState CEO - PC Prep Script
# Place this file in D:\PC_Prep\ and launch via Launch.bat

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -- Configuration ------------------------------------------------------------
$DownloadPath  = 'C:\Users\CEOIT\Downloads'
$PcPrepRoot    = 'D:\PC_Prep'
$LogFile       = "$DownloadPath\PCPrep_$(Get-Date -f 'yyyyMMdd_HHmmss').log"

$WifiSSID      = 'CEOWIFI'
$WifiPassword  = '#$CEO_572_Centerstate#$'
$DomainName    = 'MDACNY.local'

$SyxsenseMSI   = Join-Path $PcPrepRoot 'syxsense.msi'
$SentinelMSI   = Join-Path $PcPrepRoot 'sentinel.msi'
$SentinelToken = 'eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1wYXg4LWV4c3Auc2VudGluZWxvbmUubmV0IiwgInNpdGVfa2V5IjogIjU5Mjk4YThlZTNlMjRkZDYifQ=='

# NOTE: Cisco folder uses "PC Prep" with a space, per the provided path
$CiscoBase     = 'D:\PC Prep\cisco-secure-client-win-5.1.14.145-predeploy-k9'
$CiscoVPN      = Join-Path $CiscoBase 'cisco-secure-client-win-5.1.14.145-core-vpn-predeploy-k9.msi'
$CiscoUmbr     = Join-Path $CiscoBase 'cisco-secure-client-win-5.1.14.145-umbrella-predeploy-k9.msi'
$OrgInfoSrc    = 'D:\PC Prep\OrgInfo.json'
$UmbrellaDest  = 'C:\ProgramData\Cisco\Cisco Secure Client\Umbrella'

# -- Step engine --------------------------------------------------------------
$Results      = [ordered]@{}
$script:WUJob = $null

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host ("`n  +-- {0}" -f $Name) -ForegroundColor Yellow
    try {
        & $Action
        $script:Results[$Name] = 'PASSED'
        Write-Host ("  +-- [DONE] {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $msg = $_.Exception.Message
        $script:Results[$Name] = "FAILED: $msg"
        Write-Host ("  +-- [FAIL] {0}" -f $Name) -ForegroundColor Red
        Write-Host ("             $msg") -ForegroundColor DarkRed
    }
}

function Install-MSI {
    param([string]$Path, [string]$ExtraArgs = '')
    if (-not (Test-Path $Path)) { throw "Installer not found: $Path" }
    $argList = "/i `"$Path`" /quiet /norestart"
    if ($ExtraArgs) { $argList += " $ExtraArgs" }
    $p = Start-Process 'msiexec.exe' -ArgumentList $argList -Wait -PassThru
    # 1638 = a higher-version product is already installed
    if ($p.ExitCode -notin @(0, 3010, 1638)) { throw "msiexec.exe exited with code $($p.ExitCode)" }
}

function Install-Exe {
    param([string]$Path, [string]$Arguments)
    if (-not (Test-Path $Path)) { throw "Installer not found: $Path" }
    $p = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    if ($p.ExitCode -notin @(0, 3010)) { throw "Installer exited with code $($p.ExitCode)" }
}

function Get-Download {
    param([string]$Url, [string]$OutFile)
    Write-Host "     Downloading: $(Split-Path $OutFile -Leaf)" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    if (-not (Test-Path $OutFile)) { throw "Download failed - file not found at: $OutFile" }
}

function Invoke-Winget {
    param([string]$Id, [string]$Source = '')
    Write-Host "     winget install $Id" -ForegroundColor DarkGray
    $wArgs = @('install', '--id', $Id, '--silent', '--scope', 'machine',
               '--accept-package-agreements', '--accept-source-agreements')
    if ($Source) { $wArgs += '--source'; $wArgs += $Source }
    $output = & winget @wArgs 2>&1
    # 0 = success; -1978335189 (0x8A15002B) = already installed / no upgrade needed
    if ($LASTEXITCODE -notin @(0, -1978335189)) {
        $outStr = $output -join "`n"
        throw "winget install '$Id' failed (exit $LASTEXITCODE). Output: $outStr"
    }
}

function Remove-AppIfPresent {
    param([string]$NamePattern)
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $app = $regPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -like "*$NamePattern*" } | Select-Object -First 1

    if (-not $app) {
        Write-Host "     Not installed (skipping): $NamePattern" -ForegroundColor DarkGray
        return
    }

    Write-Host "     Removing: $($app.DisplayName)" -ForegroundColor DarkGray

    # Prefer GUID-based MSI uninstall
    if ($app.PSChildName -match '^\{') {
        $p = Start-Process 'msiexec.exe' `
            -ArgumentList "/x `"$($app.PSChildName)`" /quiet /norestart" -Wait -PassThru
        if ($p.ExitCode -notin @(0, 3010, 1605)) {
            throw "msiexec /x exited $($p.ExitCode) for '$($app.DisplayName)'"
        }
        return
    }

    # Fall back to recorded uninstall string
    $cmd = if ($app.QuietUninstallString) { $app.QuietUninstallString } else { $app.UninstallString }
    if (-not $cmd) { throw "No uninstall string found for '$($app.DisplayName)'" }
    if ($cmd -imatch 'msiexec' -and $cmd -notmatch '/quiet') { $cmd += ' /quiet /norestart' }

    if ($cmd -match '^"([^"]+)"\s*(.*)$') {
        $p = Start-Process -FilePath $Matches[1] -ArgumentList $Matches[2] -Wait -PassThru
    } else {
        $p = Start-Process -FilePath $cmd -Wait -PassThru
    }
    if ($p.ExitCode -notin @(0, 3010, 1605)) {
        throw "Uninstall exited $($p.ExitCode) for '$($app.DisplayName)'"
    }
    Write-Host "     Removed: $($app.DisplayName)" -ForegroundColor DarkGray
}

function Test-AppInstalled {
    param([string]$NamePattern)
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $found = $regPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -like "*$NamePattern*" } | Select-Object -First 1
    return ($null -ne $found)
}

# -- Pre-flight ---------------------------------------------------------------
if (-not (Test-Path $DownloadPath)) {
    New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
}
Start-Transcript -Path $LogFile -Append | Out-Null

$wlanSvc = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue
if ($wlanSvc -and $wlanSvc.Status -ne 'Running') { Start-Service 'WlanSvc' }

# -- Banner -------------------------------------------------------------------
$HR  = '=' * 64
$now = Get-Date -f 'yyyy-MM-dd HH:mm'
Write-Host "`n$HR" -ForegroundColor Cyan
Write-Host "  CenterState CEO  --  PC Prep Script  |  $now" -ForegroundColor Cyan
Write-Host "$HR`n" -ForegroundColor Cyan

# =============================================================================
# 01. Connect to WiFi
# =============================================================================
Invoke-Step '01. Connect to WiFi' {
    $online = Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($online) {
        Write-Host '     Internet already available -- skipping WiFi setup.' -ForegroundColor DarkGray
        return
    }

    $profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$WifiSSID</name>
  <SSIDConfig>
    <SSID><name>$WifiSSID</name></SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$WifiPassword</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
    $tmpXml = "$env:TEMP\ceo_wlan_profile.xml"
    $profileXml | Out-File -FilePath $tmpXml -Encoding UTF8
    netsh wlan add profile filename="$tmpXml" | Out-Null
    netsh wlan connect name="$WifiSSID" | Out-Null
    Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue

    $deadline = (Get-Date).AddSeconds(30)
    $connected = $false
    do {
        Start-Sleep -Seconds 3
        $connected = Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue
    } while (-not $connected -and (Get-Date) -lt $deadline)

    if (-not $connected) { throw "Associated to $WifiSSID but no internet after 30 s. Check AP or credentials." }
    Write-Host "     Connected to $WifiSSID successfully." -ForegroundColor DarkGray
}

# =============================================================================
# 02. .NET 8 Desktop Runtime
# =============================================================================
Invoke-Step '02. .NET 8 Desktop Runtime' {
    $runtimeDir = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App'
    $v8 = Get-ChildItem $runtimeDir -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like '8.*' } | Select-Object -First 1
    if ($v8) {
        Write-Host "     Already installed: .NET Desktop Runtime $($v8.Name)" -ForegroundColor DarkGray
        return
    }
    $installer = "$DownloadPath\dotnet8-desktop-runtime.exe"
    Get-Download 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe' $installer
    Install-Exe $installer '/install /quiet /norestart'
}

# =============================================================================
# 03. Dell Command Update (install)
# =============================================================================
Invoke-Step '03. Dell Command Update' {
    # Remove any legacy (non-Universal) version -- it causes winget to hang
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $legacyDcu = $regPaths | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
        Where-Object {
            $_.DisplayName -like '*Dell Command*Update*' -and
            $_.DisplayName -notlike '*Universal*'
        } | Select-Object -First 1

    if ($legacyDcu) {
        Write-Host "     Found legacy version -- removing: $($legacyDcu.DisplayName)" -ForegroundColor DarkGray
        if ($legacyDcu.PSChildName -match '^\{') {
            $p = Start-Process 'msiexec.exe' `
                -ArgumentList "/x `"$($legacyDcu.PSChildName)`" /quiet /norestart" -Wait -PassThru
            if ($p.ExitCode -notin @(0, 3010, 1605)) { throw "Legacy removal exited $($p.ExitCode)" }
        } else {
            $cmd = if ($legacyDcu.QuietUninstallString) { $legacyDcu.QuietUninstallString } else { $legacyDcu.UninstallString }
            if (-not $cmd) { throw "No uninstall string found for $($legacyDcu.DisplayName)" }
            if ($cmd -match '^"([^"]+)"\s*(.*)$') {
                $p = Start-Process -FilePath $Matches[1] -ArgumentList $Matches[2] -Wait -PassThru
            } else {
                $p = Start-Process -FilePath $cmd -Wait -PassThru
            }
            if ($p.ExitCode -notin @(0, 3010, 1605)) { throw "Legacy removal exited $($p.ExitCode)" }
        }
        Write-Host '     Legacy version removed.' -ForegroundColor DarkGray
    } else {
        Write-Host '     No legacy version found.' -ForegroundColor DarkGray
    }

    Invoke-Winget 'Dell.CommandUpdate.Universal' -Source 'winget'
}

# =============================================================================
# 04. Remove Dell SupportAssist bloatware
#     More specific patterns removed first so the broad "SupportAssist" pass
#     only catches the main app if it is still present.
# =============================================================================
Invoke-Step '04. Remove Dell SupportAssist Apps' {
    Remove-AppIfPresent 'SupportAssist Remediation'
    Remove-AppIfPresent 'SupportAssist OS Recovery Plugin'
    Remove-AppIfPresent 'Dell SupportAssist'
    Remove-AppIfPresent 'Dell Trusted Device'
}

# =============================================================================
# 05. Syxsense
# =============================================================================
Invoke-Step '05. Syxsense' {
    if (Test-AppInstalled 'Syxsense') {
        Write-Host '     Already installed: Syxsense' -ForegroundColor DarkGray
        return
    }
    Install-MSI $SyxsenseMSI
}

# =============================================================================
# 06. Cisco Secure Client -- VPN (AnyConnect)
# =============================================================================
Invoke-Step '06. Cisco Secure Client -- VPN' {
    # Check for VPN core specifically -- exclude Umbrella-only entries
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $vpnEntry = $regPaths | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -like '*Cisco Secure Client*' -and $_.DisplayName -notlike '*Umbrella*' } |
        Select-Object -First 1
    if ($vpnEntry) {
        Write-Host "     Already installed: $($vpnEntry.DisplayName)" -ForegroundColor DarkGray
        return
    }
    Install-MSI $CiscoVPN
}

# =============================================================================
# 07. Cisco Secure Client -- Umbrella
# =============================================================================
Invoke-Step '07. Cisco Secure Client -- Umbrella' {
    if (Test-AppInstalled 'Umbrella Roaming') {
        Write-Host '     Already installed: Cisco Umbrella Roaming Security' -ForegroundColor DarkGray
        return
    }
    Install-MSI $CiscoUmbr
}

# =============================================================================
# 08. Deploy Umbrella OrgInfo.json
# =============================================================================
Invoke-Step '08. Umbrella OrgInfo.json config' {
    if (-not (Test-Path $OrgInfoSrc)) { throw "Config file not found: $OrgInfoSrc" }
    if (-not (Test-Path $UmbrellaDest)) {
        New-Item -Path $UmbrellaDest -ItemType Directory -Force | Out-Null
    }
    Copy-Item -Path $OrgInfoSrc -Destination $UmbrellaDest -Force
    Write-Host "     Copied OrgInfo.json to $UmbrellaDest" -ForegroundColor DarkGray
}

# =============================================================================
# 09. Adobe Acrobat Reader
# =============================================================================
Invoke-Step '09. Adobe Acrobat Reader' {
    Invoke-Winget 'Adobe.Acrobat.Reader.64-bit' -Source 'winget'
}

# =============================================================================
# 10. Zoom
# =============================================================================
Invoke-Step '10. Zoom' {
    if (Test-AppInstalled 'Zoom') {
        Write-Host '     Already installed: Zoom' -ForegroundColor DarkGray
        return
    }
    $installer = "$DownloadPath\ZoomInstallerFull.exe"
    Get-Download 'https://zoom.us/client/latest/ZoomInstallerFull.exe' $installer
    Install-Exe $installer '/quiet /norestart'
}

# =============================================================================
# 11. Slack
# =============================================================================
Invoke-Step '11. Slack' {
    Invoke-Winget 'SlackTechnologies.Slack' -Source 'winget'
}

# =============================================================================
# 12. Microsoft Teams
# =============================================================================
Invoke-Step '12. Microsoft Teams' {
    Invoke-Winget 'Microsoft.Teams' -Source 'winget'
}

# =============================================================================
# 13. Join Domain
# =============================================================================
Invoke-Step "13. Join Domain ($DomainName)" {
    Write-Host '     A credential dialog will appear -- enter domain admin credentials.' -ForegroundColor DarkGray
    $cred = Get-Credential -Message "Enter domain admin credentials for $DomainName"
    Add-Computer -DomainName $DomainName -Credential $cred -ErrorAction Stop
    Write-Host '     Domain join staged. A reboot is required to finalize.' -ForegroundColor DarkYellow
}

# =============================================================================
# 14. Windows Update (background job -- script continues to step 15)
# =============================================================================
Invoke-Step '14. Windows Update' {
    Write-Host '     Installing PSWindowsUpdate module...' -ForegroundColor DarkGray
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module -Name PSWindowsUpdate -Force -AllowClobber -Scope AllUsers | Out-Null

    Write-Host '     Starting Windows Update in the background...' -ForegroundColor DarkGray
    $script:WUJob = Start-Job -ScriptBlock {
        Import-Module PSWindowsUpdate -Force
        Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false
    }
    Write-Host ("     Windows Update job started (ID: {0}) -- continuing script." -f $script:WUJob.Id) -ForegroundColor DarkYellow
}

# =============================================================================
# 15. Dell Command Update -- Apply Driver Updates
# =============================================================================
Invoke-Step '15. Dell Command Update -- Apply Updates' {
    $dcuCli = @(
        'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
        'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $dcuCli) {
        throw 'dcu-cli.exe not found. Dell Command Update may need a reboot first to finish installing.'
    }

    Write-Host '     Scanning and applying Dell driver updates (may take several minutes)...' -ForegroundColor DarkGray
    $p = Start-Process -FilePath $dcuCli `
        -ArgumentList '/applyUpdates -autoSuspendBitLocker=enable -silent' `
        -Wait -PassThru
    # 0 = success, 1 = reboot required, 5 = no updates found
    if ($p.ExitCode -notin @(0, 1, 5)) { throw "dcu-cli.exe exited with code $($p.ExitCode)" }
}

# =============================================================================
# 16. Sentinel One (installed last so it does not flag earlier install activity)
# =============================================================================
Invoke-Step '16. Sentinel One' {
    if ((Get-Service 'SentinelAgent' -ErrorAction SilentlyContinue) -or (Test-AppInstalled 'Sentinel Agent')) {
        Write-Host '     Already installed: Sentinel One' -ForegroundColor DarkGray
        return
    }
    Install-MSI $SentinelMSI "SITE_TOKEN=`"$SentinelToken`""
}

# -- Wait for background Windows Update job -----------------------------------
if ($null -ne $script:WUJob) {
    Write-Host "`n  Waiting for Windows Update to finish (up to 45 min)..." -ForegroundColor Yellow
    $completed = Wait-Job -Job $script:WUJob -Timeout 2700
    $jobState  = $script:WUJob.State
    Receive-Job -Job $script:WUJob | Out-Null
    Remove-Job  -Job $script:WUJob -Force

    if ($completed -and $jobState -eq 'Completed') {
        $Results['14. Windows Update'] = 'PASSED'
        Write-Host '  +-- [DONE] 14. Windows Update (background)' -ForegroundColor Green
    } elseif (-not $completed) {
        $Results['14. Windows Update'] = 'FAILED: Timed out after 45 minutes'
        Write-Host '  +-- [FAIL] 14. Windows Update: timed out after 45 minutes' -ForegroundColor Red
    } else {
        $Results['14. Windows Update'] = "FAILED: Job ended in state '$jobState'"
        Write-Host ("  +-- [FAIL] 14. Windows Update: job state = {0}" -f $jobState) -ForegroundColor Red
    }
}

# -- Final Summary ------------------------------------------------------------
Write-Host "`n$HR" -ForegroundColor Cyan
Write-Host '  FINAL SUMMARY' -ForegroundColor Cyan
Write-Host $HR -ForegroundColor Cyan

$passed = 0; $failed = 0
foreach ($entry in $Results.GetEnumerator()) {
    if ($entry.Value -eq 'PASSED') {
        Write-Host ("  [PASS]  {0}" -f $entry.Key) -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host ("  [FAIL]  {0}" -f $entry.Key) -ForegroundColor Red
        Write-Host ("          {0}" -f $entry.Value) -ForegroundColor DarkRed
        $failed++
    }
}

$hr2 = '-' * 64
$summaryColor = if ($failed -eq 0) { 'Green' } else { 'Yellow' }
Write-Host $hr2 -ForegroundColor Cyan
Write-Host ("  Passed: {0}   Failed: {1}" -f $passed, $failed) -ForegroundColor $summaryColor
Write-Host ("  Log:    {0}" -f $LogFile) -ForegroundColor DarkGray
Write-Host "$HR`n" -ForegroundColor Cyan

Stop-Transcript | Out-Null

Write-Host 'IMPORTANT: A reboot is required to finalize the domain join and pending updates.' -ForegroundColor Yellow
$ans = Read-Host 'Reboot now? [Y/N]'
if ($ans -match '^[Yy]') {
    Write-Host 'Rebooting in 5 seconds...' -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
