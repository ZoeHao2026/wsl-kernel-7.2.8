<#
.SYNOPSIS
    One-command deploy for the WSL custom kernel: kernel artifacts + environment fixes.

.DESCRIPTION
    Two parts:

      1. Kernel - download bzImage / modules disk / System.map / config from a GitHub
         release into a fixed directory, verify SHA-256, then update
         %USERPROFILE%\.wslconfig. Paths MUST use forward slashes; with backslashes
         WSL silently falls back to its bundled kernel (see README).

      2. Environment - call deploy/wsl-env/install.sh inside WSL, which installs the
         X11 socket fallback, zram compressed swap, and the wsl-gpu toggle.

    Deliberately safe to re-run:
      * idempotent - only files whose content differs are rewritten
      * .wslconfig is backed up to .wslconfig.bak-<timestamp> before editing
      * only the keys this script owns are touched; other keys are preserved
      * -DryRun prints the plan without writing anything

    NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 decodes .ps1
    files using the system ANSI code page, so non-ASCII characters here get mangled
    and break parsing outright - which is also why you will not find Chinese text in
    this file even though the rest of the repo is bilingual.

.PARAMETER Tag
    Release tag to download kernel artifacts from.

.PARAMETER KernelDir
    Local directory holding the kernel artifacts (highest priority over -Tag).

.PARAMETER TargetDir
    Where kernel artifacts are placed. Defaults to %USERPROFILE%\wsl-kernel\<release ref>.

.PARAMETER SkipEnv
    Deploy the kernel only; do not call the WSL-side installer.

.PARAMETER SkipKernel
    Deploy the environment only (same as running install.sh inside WSL).

.PARAMETER DryRun
    Print what would happen, change nothing.

.EXAMPLE
    .\deploy\install.ps1 -Tag v7.2.8-wsl-kernel.3

.EXAMPLE
    .\deploy\install.ps1 -KernelDir C:\path\to\artifacts

.EXAMPLE
    .\deploy\install.ps1 -SkipKernel      # environment fixes only
#>
[CmdletBinding()]
param(
    # Empty = follow the newest release. Windows PowerShell 5.1 does not accept
    # "latest" as a default for this kind of parameter, so the empty string is
    # used as the "unset" marker and resolved to releases/latest below.
    # Pin an exact build with e.g. -Tag v7.2.8-wsl-kernel.3.
    [string]$Tag = '',
    [string]$Repo = 'ZoeHao2026/wsl-kernel-7.2.8',
    [string]$KernelDir,
    [string]$TargetDir,
    [string]$Distro = 'Ubuntu-26.04',
    [int]$MemoryGB = 24,
    [switch]$SkipEnv,
    [switch]$SkipKernel,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Rel = '7.2.8-microsoft-standard-WSL2'

# Resolve the release reference. A pinned tag keeps every download on that exact
# build; otherwise follow "latest" so this never goes stale.
if ($Tag) {
    $RelBase = "https://github.com/$Repo/releases/download/$Tag"
    $RelRef  = $Tag
} else {
    $RelBase = "https://github.com/$Repo/releases/latest/download"
    $RelRef  = 'latest'
}

$Names = @{
    Kernel  = "bzImage-$Rel"
    Modules = "modules-$Rel.vhdx"
    Sysmap  = "System.map-$Rel"
    Config  = "config-$Rel"
}
if (-not $TargetDir) { $TargetDir = Join-Path $env:USERPROFILE "wsl-kernel\$RelRef" }

function Say  { param([string]$m) Write-Host $m }
function Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "  + $m" -ForegroundColor Green }
function Skip { param([string]$m) Write-Host "  = $m" }
function Warn { param([string]$m) Write-Host "  ! $m" -ForegroundColor Yellow }

function Get-FileSha256 { param([string]$p) (Get-FileHash $p -Algorithm SHA256).Hash.ToLower() }

# wsl.exe writes its own messages (like "wsl -l -q" and "wslpath -w" output) as
# UTF-16LE. Reading that into a normal .NET string leaves interleaved NUL bytes,
# so a plain -match on the distro name silently fails. Strip them first.
function Invoke-WslText {
    param([string[]]$WslArgs)
    $raw = & wsl.exe @WslArgs 2>&1 | Out-String
    ($raw -replace "`0", '').Trim()
}

# ------------------------------------------------------------------- artifacts
function Resolve-KernelArtifacts {
    param([string]$Dir)

    Step "Prepare kernel artifacts in $Dir"
    $missing = @()
    foreach ($k in $Names.Keys) {
        if (-not (Test-Path (Join-Path $Dir $Names[$k]))) { $missing += $Names[$k] }
    }
    if ($missing.Count -eq 0) { Ok "all four artifacts present"; return }

    Warn "missing: $($missing -join ', ')"

    # The modules disk is published as 58 parts, so the single file is usually absent.
    if ($missing -contains $Names.Modules) {
        $complete = Join-Path $Dir $Names.Modules
        $reasm = Join-Path $RepoRoot 'scripts\reassemble-modules-vhdx.ps1'
        if ($DryRun) {
            Say "  [dry-run] download the 58 module-disk parts and rebuild it"
        } elseif (Test-Path $reasm) {
            Warn "rebuilding the modules disk from release parts"
            if ($RelRef -eq 'latest') {
                & $reasm -OutFile $complete -Repo $Repo 2>&1 | ForEach-Object { "    $_" }
            } else {
                & $reasm -OutFile $complete -Repo $Repo -Tag $RelRef 2>&1 | ForEach-Object { "    $_" }
            }
            if (-not (Test-Path $complete)) { throw "modules disk rebuild failed" }
            Ok "modules disk rebuilt"
        } else {
            throw "modules disk missing and $reasm not found"
        }
    }

    foreach ($k in @('Kernel','Sysmap','Config')) {
        $p = Join-Path $Dir $Names[$k]
        if (Test-Path $p) { continue }
        $url = "$RelBase/$($Names[$k])"
        if ($DryRun) { Say "  [dry-run] download $($Names[$k])"; continue }
        Warn "downloading $($Names[$k])"
        Invoke-WebRequest -Uri $url -OutFile $p -UseBasicParsing
        Ok "downloaded $($Names[$k])"
    }

    if (-not $DryRun) {
        $still = @()
        foreach ($k in $Names.Keys) {
            if (-not (Test-Path (Join-Path $Dir $Names[$k]))) { $still += $Names[$k] }
        }
        if ($still.Count) { throw "still missing: $($still -join ', ')" }
    }
}

function Test-KernelArtifacts {
    param([string]$Dir)
    Step "Verify SHA-256"
    $sums = Join-Path $Dir 'SHA256SUMS'
    if (-not (Test-Path $sums)) {
        $url = "$RelBase/SHA256SUMS"
        if ($DryRun) { Say "  [dry-run] fetch SHA256SUMS and verify every artifact"; return }
        try { Invoke-WebRequest -Uri $url -OutFile $sums -UseBasicParsing }
        catch { Warn "cannot fetch SHA256SUMS; skipping verification"; return }
    }
    $expect = @{}
    foreach ($line in Get-Content $sums) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $expect[$Matches[2].Trim()] = $Matches[1].ToLower() }
    }
    $bad = 0; $checked = 0
    foreach ($k in $Names.Keys) {
        $n = $Names[$k]; $p = Join-Path $Dir $n
        if (-not (Test-Path $p)) { continue }
        if (-not $expect.ContainsKey($n)) { Skip "$n (not listed; skipped)"; continue }
        $h = Get-FileSha256 $p
        if ($h -eq $expect[$n]) { Ok "$n verified"; $checked++ }
        else { Warn "$n MISMATCH`n      expected $($expect[$n])`n      actual   $h"; $bad++ }
    }
    if ($bad) { throw "$bad artifact(s) failed verification - aborting deployment" }
    if (-not $checked) { Warn "nothing to verify" }
}

function Show-KernelFingerprint {
    Step "Current WSL kernel fingerprint (to confirm the deploy actually took effect)"
    $v = (& wsl.exe -d $Distro -e bash -lc 'uname -r; uname -v' 2>&1 | Out-String)
    $v.Trim().Split("`n") | ForEach-Object { Say ("  " + $_.Trim()) }
}

# ------------------------------------------------------------------ .wslconfig
function Update-WslConfig {
    param([string]$KernelPath, [string]$ModulesPath, [int]$MemGB)

    Step "Update .wslconfig"
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    # Forward slashes are mandatory; backslashes make WSL silently fall back.
    $kernelLine  = 'kernel='        + ($KernelPath  -replace '\\','/')
    $modulesLine = 'kernelModules=' + ($ModulesPath -replace '\\','/')

    if (-not (Test-Path $cfg)) {
        if ($DryRun) { Say "  [dry-run] create $cfg"; return }
        Warn "$cfg does not exist; creating it"
        Set-Content -Path $cfg -Value @('[wsl2]', $kernelLine, $modulesLine, "memory=${MemGB}GB") -Encoding ASCII
        Ok "created $cfg"
        return
    }

    $backup = "$cfg.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    $lines = Get-Content $cfg
    $out = New-Object System.Collections.Generic.List[string]
    $seenK = $false; $seenM = $false; $seenMem = $false; $inWsl2 = $false
    $sawSection = $false

    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+)\]\s*$') {
            $inWsl2 = ($Matches[1] -eq 'wsl2')
            if ($inWsl2) { $sawSection = $true }
            $out.Add($l); continue
        }
        if ($inWsl2 -and $l -match '^\s*kernel\s*=')        { $out.Add($kernelLine);  $seenK = $true;  continue }
        if ($inWsl2 -and $l -match '^\s*kernelModules\s*=') { $out.Add($modulesLine); $seenM = $true;  continue }
        if ($inWsl2 -and $l -match '^\s*memory\s*=')        { $out.Add("memory=${MemGB}GB"); $seenMem = $true; continue }
        $out.Add($l)
    }

    if (-not $sawSection) {
        $out.Insert(0, '[wsl2]')
        $out.Insert(1, $kernelLine)
        $out.Insert(2, $modulesLine)
        $out.Insert(3, "memory=${MemGB}GB")
    } else {
        if (-not $seenK)   { $out.Add($kernelLine) }
        if (-not $seenM)   { $out.Add($modulesLine) }
        if (-not $seenMem) { $out.Add("memory=${MemGB}GB") }
    }

    if ($DryRun) {
        Say "  [dry-run] back up $cfg -> $backup"
        Say "  [dry-run] resulting content:"
        $out | ForEach-Object { Say "      $_" }
        return
    }
    Copy-Item $cfg $backup -Force
    Say "  backed up -> $backup"
    Set-Content -Path $cfg -Value $out -Encoding ASCII
    Ok "wrote $cfg (kernel / kernelModules / memory=${MemGB}GB)"
}

# -------------------------------------------------------------------- WSL env
function Invoke-WslEnvInstall {
    Step "Install environment fixes inside WSL (X11 / zram / GPU toggle)"
    $src = Join-Path $RepoRoot 'deploy\wsl-env'
    if (-not (Test-Path $src)) { Warn "$src not found; skipping"; return }

    $distros = Invoke-WslText @('-l', '-q')
    if ($distros -notmatch [regex]::Escape($Distro)) {
        Warn "distro $Distro not found; skipping. Present:`n$distros"
        return
    }

    if ($DryRun) {
        Say "  [dry-run] would run inside WSL as root:"
        Say "      cd $src && chmod +x install.sh && ./install.sh"
        Say "  [dry-run] if that path is not reachable from Windows, the assets are"
        Say "            copied into a WSL /tmp dir first and run from there."
        return
    }

    # Find the repo inside WSL. If Windows cannot see it (repo lives in the WSL
    # filesystem), copy the assets to a temp dir inside WSL instead.
    $winRepo = $RepoRoot -replace '\\','/'
    $wslPath = Invoke-WslText @('-d', $Distro, '-e', 'bash', '-lc', "if [ -d '$winRepo' ]; then echo '$winRepo'; fi")

    if (-not $wslPath -or $wslPath -notmatch '/') {
        Warn "repo path not visible from Windows; copying assets into WSL /tmp"
        $tmpd = Invoke-WslText @('-d', $Distro, '-e', 'bash', '-lc', 'mktemp -d /tmp/wsl-kdeploy.XXXXXX')
        if (-not $tmpd -or $tmpd -notmatch '^/tmp/') { throw "could not create temp dir inside WSL (got '$tmpd')" }
        $winTmp = Invoke-WslText @('-d', $Distro, '-e', 'bash', '-lc', "wslpath -w '$tmpd'")
        if (-not $winTmp) { throw "wslpath returned nothing for $tmpd" }
        Copy-Item (Join-Path $src '*') $winTmp -Recurse -Force
        $wslPath = $tmpd
        Say "  assets copied to $tmpd"
    }

    Say "  running: install.sh inside $Distro (as root)"
    # Strip CR defensively: these files must run under bash in WSL.
    $cmd = "cd '$wslPath' && sed -i 's/\r$//' install.sh && chmod +x install.sh && ./install.sh"
    & wsl.exe -d $Distro -u root -e bash -lc $cmd 2>&1 | ForEach-Object { "    $_" }
    if ($LASTEXITCODE -ne 0) { Warn "WSL environment install returned $LASTEXITCODE - see output above" }
    else { Ok "WSL environment install finished" }
}

# ============================================================================
Say "WSL custom kernel - one-command deploy" -ForegroundColor White
Say "  repo        : $Repo"
Say "  release     : $RelRef"
Say "  kernel ver  : $Rel"
Say "  artifacts   : $TargetDir"
Say "  distro      : $Distro"
Say "  memory cap  : ${MemoryGB}GB"
if ($DryRun) { Say "  mode        : DRY-RUN (nothing will be changed)" -ForegroundColor Yellow }

Show-KernelFingerprint

if (-not $SkipKernel) {
    if ($KernelDir) {
        Step "Copy kernel artifacts from $KernelDir"
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null }
        foreach ($k in $Names.Keys) {
            $s = Join-Path $KernelDir $Names[$k]
            $d = Join-Path $TargetDir  $Names[$k]
            if (-not (Test-Path $s)) { Warn "missing $($Names[$k]) - will try the release"; continue }
            if ((Test-Path $d) -and ((Get-FileSha256 $s) -eq (Get-FileSha256 $d))) { Skip "$($Names[$k]) up to date"; continue }
            if ($DryRun) { Say "  [dry-run] copy $($Names[$k])"; continue }
            Copy-Item $s $d -Force; Ok "copied $($Names[$k])"
        }
    }
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null }
    Resolve-KernelArtifacts -Dir $TargetDir
    Test-KernelArtifacts -Dir $TargetDir
    Update-WslConfig -KernelPath (Join-Path $TargetDir $Names.Kernel) -ModulesPath (Join-Path $TargetDir $Names.Modules) -MemGB $MemoryGB
}

if (-not $SkipEnv) { Invoke-WslEnvInstall }

Step "Done"
if ($SkipKernel) {
    Say "  environment only; kernel untouched."
} else {
    Say "  kernel artifacts are in place but NOT active yet - restart WSL:"
    Say "      wsl --shutdown"
    Say ("      wsl -d {0} -- uname -r     # expect {1}" -f $Distro, $Rel)
    Say "      wsl -d $Distro -- uname -v     # expect a different build time than above"
    Warn "replacing bzImage alone is not enough: WSL reuses the running VM, so only"
    Warn "uname -v proves the new kernel actually booted."
}
Say ""
Say ("  inspect the environment fixes: wsl -d {0} -u root -e bash <repo>/deploy/wsl-env/install.sh --status" -f $Distro)
Say "  rollback: .wslconfig backups are .wslconfig.bak-* next to it; old kernel artifacts per README."

