<#
.SYNOPSIS
    Rebuild modules-7.2.8-microsoft-standard-WSL2.vhdx from release parts.

.DESCRIPTION
    Why the modules disk is split: POSTs from this network to
    uploads.github.com are reset by the peer at roughly 16 MiB - both a
    16 MiB and a 40 MiB test body were cut at about 16.7 MB - so the
    243 MB modules disk cannot be published as one file. Attachments
    larger than 48 MiB are therefore published in 4 MiB parts.

    This script downloads every part, verifies each part's SHA-256,
    concatenates them, then verifies the SHA-256 of the whole file.
    Any failure aborts, so it never leaves behind a VHDX that looks
    fine but is silently corrupt.

    NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1
    decodes .ps1 files using the system ANSI code page, so non-ASCII
    text here would be mangled and can break parsing outright.

.PARAMETER OutFile
    Output path. Defaults to modules-7.2.8-microsoft-standard-WSL2.vhdx
    in the current directory.

.PARAMETER KeepParts
    Keep the downloaded part directory (removed by default).

.EXAMPLE
    .\reassemble-modules-vhdx.ps1
    Downloads all parts and writes modules-7.2.8-microsoft-standard-WSL2.vhdx

.EXAMPLE
    .\reassemble-modules-vhdx.ps1 -UseDirectUrl
    Skip the GitHub CLI and fetch each part over its public URL.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path (Get-Location) 'modules-7.2.8-microsoft-standard-WSL2.vhdx'),
    [string]$Repo = 'ZoeHao2026/wsl-kernel-7.2.8',
    [string]$Tag = 'v7.2.8-wsl-kernel.2',
    [int]$PartCount = 58,
    [string]$ExpectedVhdxSha256 = '89fe1d8d5af13c9a13b4311cc48ee63633ce55594dfcc528ad2520ce63cf0de3',
    [switch]$UseDirectUrl,
    [switch]$KeepParts
)

$ErrorActionPreference = 'Stop'
$prefix = 'modules-7.2.8-microsoft-standard-WSL2.vhdx.4m'

# Refuse to clobber silently: the user may have a modules disk in use.
if (Test-Path $OutFile) {
    $ans = Read-Host "$OutFile already exists. Overwrite? (y/N)"
    if ($ans -notmatch '^[yY]') { Write-Host 'Cancelled.'; exit 1 }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("vhdx-parts-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
Write-Host "Parts directory: $work"

try {
    # ------------------------------------------------------------- checksums
    $sumsUrl = "https://github.com/$Repo/releases/download/$Tag/PART4M-SHA256SUMS"
    $sumsFile = Join-Path $work 'PART4M-SHA256SUMS'
    Write-Host 'Downloading part checksums ...'
    Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsFile -UseBasicParsing

    $expected = @{}
    foreach ($line in Get-Content $sumsFile) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            $expected[$Matches[2].Trim()] = $Matches[1].ToLower()
        }
    }
    if ($expected.Count -eq 0) { throw "PART4M-SHA256SUMS parsed to zero entries: $sumsFile" }

    $haveGh = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)

    # ------------------------------------------------------------- download
    for ($i = 0; $i -lt $PartCount; $i++) {
        $name = '{0}{1:d2}' -f $prefix, $i
        $dest = Join-Path $work $name
        $ok = $false
        for ($attempt = 1; $attempt -le 4 -and -not $ok; $attempt++) {
            try {
                if ($UseDirectUrl -or -not $haveGh) {
                    $url = "https://github.com/$Repo/releases/download/$Tag/$name"
                    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
                } else {
                    & gh release download $Tag --repo $Repo --pattern $name --dir $work --clobber 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "gh release download failed with exit code $LASTEXITCODE" }
                }
                $ok = $true
            } catch {
                if ($attempt -eq 4) { throw "Part $name failed to download: $_" }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
        Write-Progress -Activity 'Downloading modules disk parts' -Status $name -PercentComplete (100 * ($i + 1) / $PartCount)
    }
    Write-Progress -Activity 'Downloading modules disk parts' -Completed

    # -------------------------------------------------------- verify parts
    Write-Host 'Verifying each part ...'
    foreach ($name in $expected.Keys) {
        $p = Join-Path $work $name
        if (-not (Test-Path $p)) { throw "Missing part: $name" }
        $h = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $expected[$name]) {
            throw "Corrupt part: $name`n  expected $($expected[$name])`n  actual   $h"
        }
    }
    Write-Host ("  all {0} parts match" -f $expected.Count)

    # ------------------------------------------------------------ concat
    Write-Host 'Concatenating ...'
    $outStream = [System.IO.File]::Create($OutFile)
    try {
        for ($i = 0; $i -lt $PartCount; $i++) {
            $name = '{0}{1:d2}' -f $prefix, $i
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $work $name))
            $outStream.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $outStream.Close()
    }

    # ------------------------------------------------------ verify result
    $final = (Get-FileHash $OutFile -Algorithm SHA256).Hash.ToLower()
    Write-Host "Output SHA-256: $final"
    if ($final -ne $ExpectedVhdxSha256) {
        throw ("Concatenated file does not match the expected digest.`n" +
               "  expected $ExpectedVhdxSha256`n  actual   $final`n" +
               "The file was left at $OutFile - do NOT use it.")
    }
    Write-Host 'OK - checksum verified.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Next: point %USERPROFILE%\.wslconfig at it (forward slashes are required):'
    Write-Host ("  kernelModules={0}" -f ($OutFile -replace '\\', '/'))
    Write-Host 'Then run: wsl --shutdown  - and confirm with: wsl -d <distro> -- uname -r'
} finally {
    if (-not $KeepParts) {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Parts kept at: $work"
    }
}
