# Install.ps1 - STAGE 1 (public bootstrap)
# Run with:  irm https://buyany.cloud/win | iex
#
# Keep this file small and free of anything confidential - it is public.
# It: downloads stage 2 to a user temp folder, gets the engineer's PIM role activated,
# then elevates and copies stage 2 into a locked-down C:\IT.Tmp, verifies its SHA256
# THERE (not in the user-writable temp folder) and runs it.
# NOTE: keep this file ASCII-only and saved as UTF-8 without BOM so irm | iex is safe.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- Release settings (update on every release) ---------------------------------------
$Repo   = 'v-Brad/endpoint-install'
$Tag    = 'main'
$Hash   = 'PUT-SHA256-OF-Install-Endpoint.ps1-HERE'
$PimUrl = 'https://portal.azure.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/aadgroup'
$Url    = "https://raw.githubusercontent.com/$Repo/$Tag/Install-Endpoint.ps1"
# ---------------------------------------------------------------------------------------

function Show-Message {
    param([string]$Text, [string]$Title = 'Endpoint install')
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
           IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Delivery folder: user-writable, therefore NEVER trusted or executed from.
$Stage = Join-Path $env:TEMP 'IT'
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
$Src = Join-Path $Stage 'Install-Endpoint.ps1'
Write-Host "Downloading stage 2 ($Tag)..."
Invoke-WebRequest -Uri $Url -OutFile $Src -UseBasicParsing

# This runs ELEVATED. It copies stage 2 into a locked folder, verifies the hash on the
# copy (so it cannot be swapped afterwards), cleans up and runs it.
$template = @'
$ErrorActionPreference = 'Stop'
$root = 'C:\IT.Tmp'
if (Test-Path $root) {
    if ((Get-Item $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$root is a reparse point - aborting." }
} else {
    New-Item -ItemType Directory -Path $root | Out-Null
}
& icacls $root /setowner 'Administrators' /T /C | Out-Null
& icacls $root /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T /C | Out-Null

$dst = Join-Path $root 'Install-Endpoint.ps1'
Copy-Item -LiteralPath '__SRC__' -Destination $dst -Force
if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne '__HASH__') {
    Remove-Item -LiteralPath $dst -Force
    throw 'Hash mismatch - the downloaded stage 2 file was altered. Aborting.'
}
Remove-Item -LiteralPath '__STAGE__' -Recurse -Force -ErrorAction SilentlyContinue
& $dst
'@
$payload = $template.Replace('__SRC__', $Src).Replace('__HASH__', $Hash).Replace('__STAGE__', $Stage)

if ($IsAdmin) {
    Write-Host 'Already elevated - continuing.' -ForegroundColor Green
    Invoke-Expression $payload
    return
}

# ---- Not admin: PIM activation in Edge InPrivate ---------------------------------------
$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found.' }

Show-Message ("An InPrivate Edge window will now open on the PIM activation page.`n`n" +
              "1. Activate your elevated account/group.`n" +
              "2. CLOSE the Edge window when finished - this is required to make sure your elevated account is active.`n`n" +
              "The install will continue once the window is closed.")

# Dedicated throw-away profile = Edge starts its own process, so -Wait waits for the window to close
$tmpProfile = Join-Path $env:TEMP ('EdgePIM_' + [guid]::NewGuid().ToString('N'))
Start-Process -FilePath $edge -Wait -ArgumentList @(
    '--inprivate', '--no-first-run', '--no-default-browser-check',
    "--user-data-dir=`"$tmpProfile`"", "`"$PimUrl`"")
Remove-Item $tmpProfile -Recurse -Force -ErrorAction SilentlyContinue

# ---- Elevate (UAC prompts a standard user for admin credentials) -----------------------
Write-Host 'Relaunching as administrator - enter your admin credentials when prompted...' -ForegroundColor Yellow
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
}
catch {
    throw "Elevation was cancelled or failed: $($_.Exception.Message)"
}
