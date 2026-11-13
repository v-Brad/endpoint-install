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
$Tag    = 'main'      # testing: unpinned. Use a release tag (e.g. v1.0.0) for production
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

function Show-Choice {
    param([string]$Text, [string]$Title = 'Endpoint install')
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
}

# Standard users can read the local Administrators membership; no elevation needed.
function Test-InLocalAdmins {
    param([string]$Account)
    $short = if ($Account -match '\\') { $Account.Split('\')[-1] }
             elseif ($Account -match '@') { $Account.Split('@')[0] }
             else { $Account }
    $lines = @(& net.exe localgroup Administrators 2>$null)
    $dash  = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{5,}\s*$') { $dash = $i; break } }
    $members = @($lines[($dash + 1)..($lines.Count - 1)] | Where-Object { $_ -and $_.Trim() } |
                 ForEach-Object { $_.Trim() })
    if ($members.Count -gt 0) { $members = $members[0..($members.Count - 2)] }   # drop "The command completed..." line
    foreach ($m in $members) {
        if ($m -ieq $Account -or $m.Split('\')[-1] -ieq $short) { return $true }
    }
    return $false
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

# ---- Has this PC picked up the elevated account yet? -----------------------------------
Add-Type -AssemblyName Microsoft.VisualBasic
$ElevAccount = [Microsoft.VisualBasic.Interaction]::InputBox(
    "Enter your ELEVATED admin account (e.g. INT\name or name@domain.com).`n`nLeave blank to skip the check.",
    'Elevated account', '')
if ($ElevAccount) {
    $ElevAccount = $ElevAccount.Trim()
    if (-not (Test-InLocalAdmins $ElevAccount)) {
        $r = Show-Choice ("'$ElevAccount' is not in this PC's local Administrators group yet.`n`n" +
                          "After a PIM activation the PC usually needs a restart before it recognises the account.`n`n" +
                          "Yes = restart now (then run the install again)`n" +
                          "No = continue anyway (e.g. you get admin through a group)`n" +
                          "Cancel = stop")
        if ($r -eq 'Yes') {
            & shutdown.exe /r /t 15 /c "Restarting so your elevated account is recognised. Run the install again after sign-in."
            return
        }
        if ($r -eq 'Cancel') { Write-Host 'Cancelled.'; return }
    }
}

# ---- Elevate (UAC prompts a standard user for admin credentials) -----------------------
Write-Host 'Relaunching as administrator - enter your admin credentials when prompted...' -ForegroundColor Yellow
Show-Message ("A Windows UAC prompt for 'Windows PowerShell' is about to appear.`n`n" +
              "Enter the credentials of your ELEVATED admin account ($(if ($ElevAccount) { $ElevAccount } else { 'the one you just activated in PIM' })).`n`n" +
              "If you cannot see it, check the taskbar - it can open behind other windows.")
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
}
catch {
    throw "Elevation was cancelled or failed: $($_.Exception.Message)"
}
