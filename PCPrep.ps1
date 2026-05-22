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

$CiscoBase     = 'D:\PC_Prep\cisco-secure-client-win-5.1.14.145-predeploy-k9'
$CiscoVPN      = Join-Path $CiscoBase 'cisco-secure-client-win-5.1.14.145-core-vpn-predeploy-k9.msi'
$CiscoUmbr     = Join-Path $CiscoBase 'cisco-secure-client-win-5.1.14.145-umbrella-predeploy-k9.msi'
$OrgInfoSrc    = 'D:\PC_Prep\OrgInfo.json'
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
    param([string]$Id, [string]$Source = '', [string]$Scope = 'machine')
    Write-Host "     winget install $Id" -ForegroundColor DarkGray
    $wArgs = @('install', '--id', $Id, '--silent',
               '--accept-package-agreements', '--accept-source-agreements')
    if ($Scope)  { $wArgs += '--scope';  $wArgs += $Scope  }
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
    } | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "*$NamePattern*" } |
        Select-Object -First 1

    if (-not $app) {
        Write-Host "     Not installed (skipping): $NamePattern" -ForegroundColor DarkGray
        return
    }

    Write-Host "     Removing: $($app.DisplayName)" -ForegroundColor DarkGray

    if ($app.PSChildName -match '^\{') {
        $p = Start-Process 'msiexec.exe' `
            -ArgumentList "/x `"$($app.PSChildName)`" /quiet /norestart" -Wait -PassThru
        if ($p.ExitCode -notin @(0, 3010, 1605)) {
            throw "msiexec /x exited $($p.ExitCode) for '$($app.DisplayName)'"
        }
        return
    }

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
    } | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "*$NamePattern*" } |
        Select-Object -First 1
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
# 02. Power and Sleep Settings
# =============================================================================
Invoke-Step '02. Power and Sleep Settings' {
    Write-Host '     Plugged in: sleep after 3 hours' -ForegroundColor DarkGray
    powercfg /change standby-timeout-ac 180
    Write-Host '     On battery: sleep after 15 minutes' -ForegroundColor DarkGray
    powercfg /change standby-timeout-dc 15
}

# =============================================================================
# 03. .NET 8 Desktop Runtime
# =============================================================================
Invoke-Step '03. .NET 8 Desktop Runtime' {
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
# 04. Dell Command Update (install)
# =============================================================================
Invoke-Step '04. Dell Command Update' {
    # Remove any legacy (non-Universal) version -- it causes winget to hang
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $legacyDcu = $regPaths | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and
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
# 05. Remove Dell SupportAssist Apps
#     More specific patterns removed first so the broad pass only catches
#     the main app if it is still present.
# =============================================================================
Invoke-Step '05. Remove Dell SupportAssist Apps' {
    Remove-AppIfPresent 'SupportAssist Remediation'
    Remove-AppIfPresent 'SupportAssist OS Recovery Plugin'
    Remove-AppIfPresent 'Dell SupportAssist'
    Remove-AppIfPresent 'Dell Trusted Device'
}

# =============================================================================
# 06. Syxsense
# =============================================================================
Invoke-Step '06. Syxsense' {
    if (Test-AppInstalled 'Syxsense') {
        Write-Host '     Already installed: Syxsense' -ForegroundColor DarkGray
        return
    }
    Install-MSI $SyxsenseMSI
}

# =============================================================================
# 07. Cisco Secure Client -- VPN (AnyConnect)
# =============================================================================
Invoke-Step '07. Cisco Secure Client -- VPN' {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $vpnEntry = $regPaths | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like '*Cisco Secure Client*' -and $_.DisplayName -notlike '*Umbrella*' } |
        Select-Object -First 1
    if ($vpnEntry) {
        Write-Host "     Already installed: $($vpnEntry.DisplayName)" -ForegroundColor DarkGray
        return
    }
    Install-MSI $CiscoVPN
}

# =============================================================================
# 08. Cisco Secure Client -- Umbrella
# =============================================================================
Invoke-Step '08. Cisco Secure Client -- Umbrella' {
    if (Test-AppInstalled 'Umbrella Roaming') {
        Write-Host '     Already installed: Cisco Umbrella Roaming Security' -ForegroundColor DarkGray
        return
    }
    Install-MSI $CiscoUmbr
}

# =============================================================================
# 09. Deploy Umbrella OrgInfo.json
# =============================================================================
Invoke-Step '09. Umbrella OrgInfo.json config' {
    if (-not (Test-Path $OrgInfoSrc)) { throw "Config file not found: $OrgInfoSrc" }
    if (-not (Test-Path $UmbrellaDest)) {
        New-Item -Path $UmbrellaDest -ItemType Directory -Force | Out-Null
    }
    Copy-Item -Path $OrgInfoSrc -Destination $UmbrellaDest -Force
    Write-Host "     Copied OrgInfo.json to $UmbrellaDest" -ForegroundColor DarkGray
}

# =============================================================================
# 10. Adobe Acrobat Reader
# =============================================================================
Invoke-Step '10. Adobe Acrobat Reader' {
    Invoke-Winget 'Adobe.Acrobat.Reader.64-bit' -Source 'winget'
}

# =============================================================================
# 11. Zoom (64-bit)
# =============================================================================
Invoke-Step '11. Zoom (64-bit)' {
    if (Test-AppInstalled 'Zoom') {
        Write-Host '     Already installed: Zoom' -ForegroundColor DarkGray
        return
    }
    $installer = "$DownloadPath\ZoomInstallerFull_x64.exe"
    Get-Download 'https://zoom.us/client/latest/ZoomInstallerFull.exe?archType=x64' $installer
    Install-Exe $installer '/quiet /norestart'
}

# =============================================================================
# 12. Slack
# =============================================================================
Invoke-Step '12. Slack' {
    Invoke-Winget 'SlackTechnologies.Slack' -Source 'winget' -Scope 'user'
}

# =============================================================================
# 13. Microsoft Teams
# =============================================================================
Invoke-Step '13. Microsoft Teams' {
    Invoke-Winget 'Microsoft.Teams' -Source 'winget'
}

# =============================================================================
# 14. Join Domain
# =============================================================================
Invoke-Step "14. Join Domain ($DomainName)" {
    $cs = Get-WmiObject -Class Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -ieq $DomainName) {
        Write-Host "     Already a member of $DomainName -- skipping." -ForegroundColor DarkGray
        return
    }
    Write-Host '     A credential dialog will appear -- enter domain admin credentials.' -ForegroundColor DarkGray
    $cred = Get-Credential -Message "Enter domain admin credentials for $DomainName"
    Add-Computer -DomainName $DomainName -Credential $cred -ErrorAction Stop
    Write-Host '     Domain join staged. Reboot required to finalize.' -ForegroundColor DarkYellow
}

# =============================================================================
# 15. Set Desktop Wallpaper for All Users
# =============================================================================
Invoke-Step '15. Set Desktop Wallpaper' {
    $wallSrc  = 'D:\PC_Prep\CenterstateCEO_LOGO.png'
    $wallDest = 'C:\Windows\Web\Wallpaper\CenterstateCEO_LOGO.png'

    if (-not (Test-Path $wallSrc)) { throw "Wallpaper file not found: $wallSrc" }

    # Copy to a system path readable by all user accounts
    Copy-Item -Path $wallSrc -Destination $wallDest -Force

    # Machine-level policy -- enforces wallpaper for all existing and future users
    $polPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path $polPath)) { New-Item -Path $polPath -Force | Out-Null }
    Set-ItemProperty -Path $polPath -Name 'Wallpaper'      -Value $wallDest -Type String
    Set-ItemProperty -Path $polPath -Name 'WallpaperStyle' -Value '10'      -Type String

    # Default user profile -- domain users will receive it on first logon
    reg load HKU\PrepWallpaper 'C:\Users\Default\NTUSER.DAT' | Out-Null
    $defDesktop = 'Registry::HKU\PrepWallpaper\Control Panel\Desktop'
    Set-ItemProperty -Path $defDesktop -Name 'Wallpaper'      -Value $wallDest
    Set-ItemProperty -Path $defDesktop -Name 'WallpaperStyle' -Value '10'
    Set-ItemProperty -Path $defDesktop -Name 'TileWallpaper'  -Value '0'
    [GC]::Collect()
    Start-Sleep -Seconds 1
    reg unload HKU\PrepWallpaper | Out-Null

    # Apply immediately to the current desktop session
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WallpaperSetter {
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
    } catch {}
    [WallpaperSetter]::SystemParametersInfo(20, 0, $wallDest, 3) | Out-Null
    Write-Host "     Wallpaper applied: $wallDest" -ForegroundColor DarkGray
}

# =============================================================================
# 16. Windows Update (background job -- script continues to step 17)
# =============================================================================
Invoke-Step '16. Windows Update' {
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
# 17. Dell Command Update -- Apply Driver Updates
# =============================================================================
Invoke-Step '17. Dell Command Update -- Apply Updates' {
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
    # 0 = success, 1 = reboot required after updates, 5 = no updates found
    # 3003 = a system restart is pending (from Windows Update etc.) -- DCU will
    #        apply driver updates on the next boot; this is expected and fine
    if ($p.ExitCode -notin @(0, 1, 5, 3003)) { throw "dcu-cli.exe exited with code $($p.ExitCode)" }
    if ($p.ExitCode -eq 3003) {
        Write-Host '     Note: a reboot is pending -- Dell driver updates will complete after restart.' -ForegroundColor DarkYellow
    }
}

# =============================================================================
# 18. Sentinel One (installed last so it does not flag earlier install activity)
# =============================================================================
Invoke-Step '18. Sentinel One' {
    if ((Get-Service 'SentinelAgent' -ErrorAction SilentlyContinue) -or (Test-AppInstalled 'Sentinel Agent')) {
        Write-Host '     Already installed: Sentinel One' -ForegroundColor DarkGray
        return
    }
    Install-MSI $SentinelMSI "SITE_TOKEN=`"$SentinelToken`""
}

# -- Wait for background Windows Update job -----------------------------------
if ($null -ne $script:WUJob) {
    Write-Host "`n  Waiting for Windows Update to finish (up to 45 min)..." -ForegroundColor Yellow
    Write-Host '  (will also stop waiting if Windows flags a reboot as required)' -ForegroundColor DarkGray

    $wuRebootKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $deadline    = (Get-Date).AddMinutes(45)
    $triggeredBy = $null

    while ($null -eq $triggeredBy -and (Get-Date) -lt $deadline) {
        if ($script:WUJob.State -in @('Completed', 'Failed', 'Stopped')) {
            $triggeredBy = 'job'
        } elseif (Test-Path $wuRebootKey) {
            $triggeredBy = 'reboot-flag'
        } else {
            Start-Sleep -Seconds 15
        }
    }

    # Clean up the job whether it finished on its own or we moved on
    if ($script:WUJob.State -eq 'Running') {
        Stop-Job -Job $script:WUJob -ErrorAction SilentlyContinue
    }
    $jobState = $script:WUJob.State
    Receive-Job -Job $script:WUJob | Out-Null
    Remove-Job  -Job $script:WUJob -Force

    switch ($triggeredBy) {
        'job' {
            if ($jobState -eq 'Completed') {
                $Results['16. Windows Update'] = 'PASSED'
                Write-Host '  +-- [DONE] 15. Windows Update (job completed)' -ForegroundColor Green
            } else {
                $Results['16. Windows Update'] = "FAILED: Job ended in state '$jobState'"
                Write-Host ("  +-- [FAIL] 15. Windows Update: job state = {0}" -f $jobState) -ForegroundColor Red
            }
        }
        'reboot-flag' {
            $Results['16. Windows Update'] = 'PASSED'
            Write-Host '  +-- [DONE] 15. Windows Update (updates installed, reboot pending)' -ForegroundColor Green
        }
        default {
            $Results['16. Windows Update'] = 'FAILED: Timed out after 45 minutes'
            Write-Host '  +-- [FAIL] 15. Windows Update: timed out after 45 minutes' -ForegroundColor Red
        }
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

# -- Timed reboot -------------------------------------------------------------
$rebootSecs = 120
Write-Host "Setup complete. This computer will reboot in $rebootSecs seconds." -ForegroundColor Yellow
Write-Host "To cancel:  Open a command prompt and run  shutdown /a" -ForegroundColor DarkGray
shutdown.exe /r /t $rebootSecs /c "PC Prep complete - rebooting to finalize domain join and updates."
