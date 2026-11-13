<#
.SYNOPSIS
    Install-Endpoint.ps1 - STAGE 2 (public, runs elevated from C:\IT.Tmp)

.DESCRIPTION
    Launched by Install.ps1 after elevation. Does the parts that are safe to be public:
      - GlobalProtect install / connect
      - Nearest-server lookup
    Then copies the PRIVATE, code-signed Install-Core.ps1 from the nearest server's it$ share
    into C:\IT.Tmp, verifies its signature there, and runs it.

    Keep this file ASCII-only. Nothing confidential belongs in it (service accounts etc. live in the core).
#>
[CmdletBinding()]
param(
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- Settings -------------------------------------------------------------------------
$VpnPortal      = 'vpnportal.vertiv.com'
$GpMsiUrl       = 'https://vpnportal.vertiv.com/global-protect/getmsi.esp'
$NearestFile    = '\\bfit01\it$\nearestserver.txt'
$ITRoot         = Join-Path $env:SystemDrive 'IT.Tmp'
$CoreRelPath    = 'Install\Install-Core.ps1'             # relative to \\<server>\it$\
$RequireSignedCore    = $false                            # set $false ONLY while testing
$CoreSignerThumbprint = 'PUT-CODE-SIGNING-CERT-THUMBPRINT-HERE'
# ---------------------------------------------------------------------------------------

function Write-Stage {
    param([string]$Text)
    Write-Host ''
    Write-Host "STAGE = $Text" -ForegroundColor Cyan
}

# Guard: this must run elevated, from the one-liner
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
           IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'This script must run elevated. Start it with:  irm https://buyany.cloud/win | iex'
}

# ---- GlobalProtect --------------------------------------------------------------------
function Test-GPConnected {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -like 'PANGP*' -and $_.Status -eq 'Up' }
    if (-not $adapter) { return $false }
    $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' }
    return [bool]$ip
}

function Get-GPExe {
    @(
        "$env:ProgramFiles\Palo Alto Networks\GlobalProtect\PanGPA.exe",
        "${env:ProgramFiles(x86)}\Palo Alto Networks\GlobalProtect\PanGPA.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

Write-Stage 'GlobalProtect'
if (Test-GPConnected) {
    Write-Host 'GlobalProtect is already connected.' -ForegroundColor Green
}
else {
    if (-not (Get-GPExe)) {
        Write-Host 'GlobalProtect not installed - downloading...'
        $msi = Join-Path $ITRoot 'GlobalProtect64.msi'
        Invoke-WebRequest -Uri $GpMsiUrl -OutFile $msi -UseBasicParsing
        if ((Get-Item $msi).Length -lt 1MB) {
            throw "Download from $GpMsiUrl did not return an MSI (file too small). Check the portal manually."
        }
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart PORTAL=`"$VpnPortal`"" -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "GlobalProtect install failed (msiexec exit code $($p.ExitCode))." }
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        Write-Host 'GlobalProtect installed.' -ForegroundColor Green
    }

    $setup = 'HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanSetup'
    if (-not (Test-Path $setup)) { New-Item $setup -Force | Out-Null }
    New-ItemProperty -Path $setup -Name 'Portal' -Value $VpnPortal -PropertyType String -Force | Out-Null

    $svc = Get-Service -Name 'PanGPS' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Start-Service PanGPS }
    if (-not (Get-Process PanGPA -ErrorAction SilentlyContinue)) { Start-Process (Get-GPExe) }

    Write-Host "Waiting for GlobalProtect to connect to $VpnPortal." -ForegroundColor Yellow
    Write-Host 'If it does not connect automatically, open the GlobalProtect tray icon and click Connect / sign in.' -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes(5)
    while (-not (Test-GPConnected)) {
        if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for the GlobalProtect connection.' }
        Start-Sleep -Seconds 3
    }
    Write-Host 'GlobalProtect connected.' -ForegroundColor Green
}

# ---- Nearest server -------------------------------------------------------------------
Write-Stage 'Nearest server'
if (-not (Test-Path -LiteralPath $NearestFile)) {
    throw "Cannot read $NearestFile - is the VPN fully up and the share reachable?"
}

$servers = foreach ($line in Get-Content -LiteralPath $NearestFile) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
    $parts = $line.Split(',') | ForEach-Object { $_.Trim() }
    if ($parts.Count -lt 2) { Write-Warning "Skipping malformed line: $line"; continue }
    [pscustomobject]@{
        Name     = $parts[0]
        IP       = $parts[1]
        Location = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        AvgMs    = $null
    }
}
if (-not $servers) { throw "No usable entries in $NearestFile." }

$pinger = New-Object System.Net.NetworkInformation.Ping
foreach ($s in $servers) {
    $times = @()
    1..4 | ForEach-Object {
        try {
            $reply = $pinger.Send($s.IP, 1000)
            if ($reply.Status -eq 'Success') { $times += $reply.RoundtripTime }
        } catch { }
    }
    if ($times.Count -gt 0) { $s.AvgMs = [math]::Round(($times | Measure-Object -Average).Average, 1) }
}
$pinger.Dispose()

$servers | Sort-Object { if ($null -eq $_.AvgMs) { [double]::MaxValue } else { $_.AvgMs } } |
    Format-Table Name, IP, Location, @{ n = 'AvgMs'; e = { if ($null -eq $_.AvgMs) { 'no reply' } else { $_.AvgMs } } } -AutoSize

$NearestServer = $servers | Where-Object { $null -ne $_.AvgMs } | Sort-Object AvgMs | Select-Object -First 1
if (-not $NearestServer) { throw 'None of the servers in the list responded to ping.' }
Write-Host "Nearest server: $($NearestServer.Name) ($($NearestServer.IP)) - $($NearestServer.Location) - $($NearestServer.AvgMs) ms" -ForegroundColor Green

# ---- Load the private core ------------------------------------------------------------
Write-Stage 'Loading install core from nearest server'
$share     = 'it$'
$coreSrc   = @("\\$($NearestServer.Name)\$share\$CoreRelPath", "\\$($NearestServer.IP)\$share\$CoreRelPath") |
             Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $coreSrc) { throw "Install-Core.ps1 not found on $($NearestServer.Name) ($CoreRelPath)." }

# Copy into the locked C:\IT.Tmp FIRST, then verify the local copy (so it cannot change after the check)
$coreLocal = Join-Path $ITRoot 'Install-Core.ps1'
Copy-Item -LiteralPath $coreSrc -Destination $coreLocal -Force

$sig = Get-AuthenticodeSignature -FilePath $coreLocal
$sigOk = ($sig.Status -eq 'Valid') -and $sig.SignerCertificate -and ($sig.SignerCertificate.Thumbprint -eq $CoreSignerThumbprint)
if (-not $sigOk) {
    $why = "Install-Core.ps1 signature check failed (status: $($sig.Status))."
    if ($RequireSignedCore) {
        Remove-Item -LiteralPath $coreLocal -Force -ErrorAction SilentlyContinue
        throw $why
    }
    Write-Warning "$why Continuing because RequireSignedCore is off (testing only)."
}
else {
    Write-Host 'Install-Core.ps1 signature verified.' -ForegroundColor Green
}

& $coreLocal -NearestServer $NearestServer -NoReboot:$NoReboot
