<#
.SYNOPSIS
    Bootstrap: fetch the deploy bundle and run deploy\install.ps1 - one command.

.DESCRIPTION
    The short path when you do not want to clone the repository:

        irm https://raw.githubusercontent.com/ZoeHao2026/wsl-kernel-7.2.8/main/deploy/bootstrap.ps1 | iex

    It downloads wsl-kernel-deploy.zip, verifies it is really a zip before
    touching your disk, unpacks it into a temp dir, and runs
    deploy\install.ps1 from there, forwarding any -FlightArgs you pass.

    Set the environment variable DSH_BOOTSTRAP_URL to exercise a different
    bundle (used by the project's own tests; normally you do not need it).

    Deliberately ASCII-only, like install.ps1: Windows PowerShell 5.1 decodes
    .ps1 files with the system ANSI code page, so non-ASCII text here would be
    mangled and can break parsing.

.EXAMPLE
    irm https://raw.githubusercontent.com/ZoeHao2026/wsl-kernel-7.2.8/main/deploy/bootstrap.ps1 | iex

.EXAMPLE
    # pass options through to install.ps1 (remaining arguments are forwarded)
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ZoeHao2026/wsl-kernel-7.2.8/main/deploy/bootstrap.ps1))) -SkipKernel -DryRun

.EXAMPLE
    # keep the unpacked bundle for inspection
    $env:DSH_BOOTSTRAP_KEEP = '1'
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ZoeHao2026/wsl-kernel-7.2.8/main/deploy/bootstrap.ps1)))
#>
[CmdletBinding()]
param(
    [string]$Tag = 'v7.2.8-wsl-kernel.2',
    [string]$Repo = 'ZoeHao2026/wsl-kernel-7.2.8',
    [string]$BundleUrl,
    [string]$WorkDir,
    # Anything after the known switches is forwarded verbatim to install.ps1.
    # Example: ... -SkipKernel -DryRun
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlightArgs
)

$ErrorActionPreference = 'Stop'

if (-not $BundleUrl) {
    if ($env:DSH_BOOTSTRAP_URL) { $BundleUrl = $env:DSH_BOOTSTRAP_URL }
    else {
        # "latest" floats to the newest release, so this one-liner never goes
        # stale. Pass -Tag to pin an exact build instead.
        if ($Tag) { $BundleUrl = "https://github.com/$Repo/releases/download/$Tag/wsl-kernel-deploy.zip" }
        else      { $BundleUrl = "https://github.com/$Repo/releases/latest/download/wsl-kernel-deploy.zip" }
    }
}
if (-not $WorkDir) {
    if ($env:DSH_BOOTSTRAP_DIR) { $WorkDir = $env:DSH_BOOTSTRAP_DIR }
    else { $WorkDir = Join-Path $env:TEMP 'wsl-kernel-deploy' }
}
$keep = ($env:DSH_BOOTSTRAP_KEEP -eq '1')

Write-Host "WSL kernel - one-command bootstrap" -ForegroundColor White
Write-Host "  bundle : $BundleUrl"
Write-Host "  workdir: $WorkDir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$zip = Join-Path $WorkDir 'wsl-kernel-deploy.zip'
$ext = Join-Path $WorkDir 'bundle'

# Download, then sanity-check that we actually got a zip. A captive portal or a
# proxy error page would otherwise be handed straight to Expand-Archive.
Write-Host "=== download ==="
$prev = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on
try {
    Invoke-WebRequest -Uri $BundleUrl -OutFile $zip -UseBasicParsing
} finally {
    $ProgressPreference = $prev
}
$len = (Get-Item $zip).Length
if ($len -lt 1024) { throw "download too small ($len bytes) - check the URL: $BundleUrl" }
$fs = [System.IO.File]::OpenRead($zip)
try {
    $magic = New-Object byte[] 2
    $null = $fs.Read($magic, 0, 2)
} finally { $fs.Close() }
if (-not ($magic[0] -eq 0x50 -and $magic[1] -eq 0x4B)) {
    throw "downloaded file is not a zip (magic $($magic[0].ToString('x2'))$($magic[1].ToString('x2'))). Check the URL / proxy."
}
Write-Host ("  ok: {0:N0} bytes" -f $len)

Write-Host "=== unpack ==="
if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $ext -Force
Write-Host "  ok: $ext"

$install = Join-Path $ext 'deploy\install.ps1'
if (-not (Test-Path $install)) {
    $found = Get-ChildItem $ext -Recurse -Filter 'install.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $install = $found.FullName } else { throw "install.ps1 not found inside the bundle" }
}
Write-Host "=== run ==="
Write-Host "  $install"
Write-Host ""

$argv = @('-ExecutionPolicy', 'Bypass', '-File', $install)
if ($FlightArgs) { $argv += $FlightArgs }
& powershell @argv
$rc = $LASTEXITCODE

if (-not $keep) {
    Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "kept: $ext"
}

if ($rc -ne 0) {
    Write-Host ""
    Write-Host "install.ps1 exited with $rc - see the output above." -ForegroundColor Yellow
    exit $rc
}
Write-Host ""
Write-Host "bootstrap done." -ForegroundColor Green
