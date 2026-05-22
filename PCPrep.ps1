#Requires -RunAsAdministrator
# CenterState CEO — PC Prep Script
# Place this file in D:\PC_Prep\ and launch via Launch.bat

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Configuration ─────────────────────────────────────────────────────────────
$DownloadPath  = 'C:\Users\CEOIT\Downloads'
$PcPrepRoot    = 'D:\PC_Prep'
$LogFile       = "$DownloadPath\PCPrep_$(Get-Date -f 'yyyyMMdd_HHmmss').log"

$WifiSSID      = 'CEOWIFI'
$WifiPassword  = '#$CEO_572_Centerstate#$'
$DomainName    = 'MDACNY.local'

$SyxsenseMSI   = Join-Path $PcPrepRoot 'syxsense.msi'
$SentinelMSI   = Join-Path $PcPrepRoot 'sentinel.msi'
$SentinelToken = 'eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1wYXg4LWV4c3Auc2VudGluZWxvbmUubmV0IiwgInNpdGVfa2V5IjogIjU5Mjk4YThlZTNlMjRkZDYifQ=='

# NOTE: Cisco files use "PC Prep" (with a space) per the provided path
$CiscoBase     = 'D:\PC Prep\cisco-secure-client-win-5.1.14.145-predeploy-k9'
$CiscoVPN      = Join-Path $CiscoBase 'cisco-secure-client-win-5.1.14.145-core-vpn-predeploy-k9.msi'
$CiscoUmbr     = Join-Path $CiscoBase 'cisco-secure-client-win-5.1.14.145-umbrella-predeploy-k9.msi'
$OrgInfoSrc    = 'D:\PC Prep\OrgInfo.json'
$UmbrellaDest  = 'C:\ProgramData\Cisco\Cisco Secure Client\Umbrella'

# ── Step engine ───────────────────────────────────────────────────────────────
$Results = [ordered]@{}

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
    if ($p.ExitCode -notin @(0, 3010)) { throw "msiexec.exe exited with code $($p.ExitCode)" }
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
    if (-not (Test-Path $OutFile)) { throw "Download failed — file missing at $OutFile" }
}

function Invoke-Winget {
    param([string]$Id)
    Write-Host "     winget install $Id" -ForegroundColor DarkGray
    $output = & winget install --id $Id --silent --scope machine `
        --accept-package-agreements --accept-source-agreements 2>&1
    # 0 = success; -1978335189 (0x8A15002B) = already installed / no upgrade needed
    if ($LASTEXITCODE -notin @(0, -1978335189)) {
        throw "winget install '$Id' failed (exit $LASTEXITCODE).`nOutput: $($output -join "`n")"
    }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
if (-not (Test-Path $DownloadPath)) {
    New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
}
Start-Transcript -Path $LogFile -Append | Out-Null

# Ensure wireless service is running (needed for WiFi step)
$wlanSvc = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue
if ($wlanSvc -and $wlanSvc.Status -ne 'Running') { Start-Service 'WlanSvc' }

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host "`n$('=' * 64)" -ForegroundColor Cyan
Write-Host "  CenterState CEO  --  PC Prep Script  |  $(Get-Date -f 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "$('=' * 64)`n" -ForegroundColor Cyan

# =============================================================================
# Step 1: Connect to WiFi
# =============================================================================
Invoke-Step '01. Connect to WiFi' {
    $online = Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($online) {
        Write-Host '     Internet already available -- skipping WiFi setup.' -ForegroundColor DarkGray
        return
    }

    # Build a WLAN profile XML and add it via netsh
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

    # Wait up to 30 seconds for internet
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
# Step 2: .NET 8 Desktop Runtime
# =============================================================================
Invoke-Step '02. .NET 8 Desktop Runtime' {
    $installer = "$DownloadPath\dotnet8-desktop-runtime.exe"
    Get-Download 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe' $installer
    Install-Exe $installer '/install /quiet /norestart'
}

# =============================================================================
# Step 3: Dell Command Update
# =============================================================================
Invoke-Step '03. Dell Command Update' {
    Invoke-Winget 'Dell.CommandUpdate.Universal'
}

# =============================================================================
# Step 4: Syxsense
# =============================================================================
Invoke-Step '04. Syxsense' {
    Install-MSI $SyxsenseMSI
}

# =============================================================================
# Step 5: Sentinel One
# =============================================================================
Invoke-Step '05. Sentinel One' {
    Install-MSI $SentinelMSI "SITE_TOKEN=`"$SentinelToken`""
}

# =============================================================================
# Step 6: Cisco Secure Client -- VPN (AnyConnect)
# =============================================================================
Invoke-Step '06. Cisco Secure Client -- VPN' {
    Install-MSI $CiscoVPN
}

# =============================================================================
# Step 7: Cisco Secure Client -- Umbrella
# =============================================================================
Invoke-Step '07. Cisco Secure Client -- Umbrella' {
    Install-MSI $CiscoUmbr
}

# =============================================================================
# Step 8: Deploy Umbrella OrgInfo.json
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
# Step 9: Adobe Acrobat Reader
# =============================================================================
Invoke-Step '09. Adobe Acrobat Reader' {
    Invoke-Winget 'Adobe.Acrobat.Reader.64-bit'
}

# =============================================================================
# Step 10: Zoom
# =============================================================================
Invoke-Step '10. Zoom' {
    $installer = "$DownloadPath\ZoomInstallerFull.exe"
    Get-Download 'https://zoom.us/client/latest/ZoomInstallerFull.exe' $installer
    Install-Exe $installer '/quiet /norestart'
}

# =============================================================================
# Step 11: Slack
# =============================================================================
Invoke-Step '11. Slack' {
    Invoke-Winget 'SlackTechnologies.Slack'
}

# =============================================================================
# Step 12: Join Domain
# =============================================================================
Invoke-Step "12. Join Domain ($DomainName)" {
    Write-Host '     A credential dialog will appear -- enter domain admin credentials.' -ForegroundColor DarkGray
    $cred = Get-Credential -Message "Enter domain admin credentials for $DomainName"
    Add-Computer -DomainName $DomainName -Credential $cred -ErrorAction Stop
    Write-Host '     Domain join staged. A reboot is required to finalize.' -ForegroundColor DarkYellow
}

# =============================================================================
# Step 13: Windows Update
# =============================================================================
Invoke-Step '13. Windows Update' {
    Write-Host '     Installing PSWindowsUpdate module...' -ForegroundColor DarkGray
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module -Name PSWindowsUpdate -Force -AllowClobber -Scope AllUsers | Out-Null
    Import-Module PSWindowsUpdate -Force
    Write-Host '     Scanning and installing updates (may take several minutes)...' -ForegroundColor DarkGray
    Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false | Out-Null
    Write-Host '     Windows Update scan complete.' -ForegroundColor DarkGray
}

# =============================================================================
# Step 14: Dell Command Update -- Apply Driver Updates
# =============================================================================
Invoke-Step '14. Dell Command Update -- Apply Updates' {
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

# ── Final Summary ─────────────────────────────────────────────────────────────
Write-Host "`n$('=' * 64)" -ForegroundColor Cyan
Write-Host '  FINAL SUMMARY' -ForegroundColor Cyan
Write-Host "$('=' * 64)" -ForegroundColor Cyan

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

$summaryColor = if ($failed -eq 0) { 'Green' } else { 'Yellow' }
Write-Host "$('─' * 64)" -ForegroundColor Cyan
Write-Host ("  Passed: {0}   Failed: {1}" -f $passed, $failed) -ForegroundColor $summaryColor
Write-Host ("  Log:    {0}" -f $LogFile) -ForegroundColor DarkGray
Write-Host "$('=' * 64)`n" -ForegroundColor Cyan

Stop-Transcript | Out-Null

Write-Host 'IMPORTANT: A reboot is required to finalize the domain join and pending updates.' -ForegroundColor Yellow
$ans = Read-Host 'Reboot now? [Y/N]'
if ($ans -match '^[Yy]') {
    Write-Host 'Rebooting in 5 seconds...' -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
