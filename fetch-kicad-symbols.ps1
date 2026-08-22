# fetch-kicad-symbols.ps1 — standalone KiCad symbol (PDB) prefetch. Runs
# independently of hunt-proc.ps1: no crash dump is required, it just
# downloads PDBs for every binary of the currently installed KiCad into the
# local symbol cache via `symchk /r`.
#
# Usage:
#   powershell -File fetch-kicad-symbols.ps1 -Channel testing
#   powershell -File fetch-kicad-symbols.ps1 -Channel nightly -KicadExe "C:\...\kicad.exe"
#
# -Channel selects one of the sibling configs
#   (hunt-proc.{nightly,testing,stable}.config.psd1) as the source of
#   SymbolCache / SymbolServers — no URLs or cache paths are hardcoded here.
#
# Deliberately interactive: it prints the installed KiCad file version, then
# pauses for an explicit confirmation before the first network request.
# Unlike hunt-proc.ps1's unattended background loop, this is a manual,
# one-shot tool.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('nightly', 'testing', 'stable')]
    [string]$Channel,

    # Default is the KiCad path used across the project configs.
    [string]$KicadExe = 'C:\Users\grand\AppData\Local\Programs\KiCad\10.0\bin\kicad.exe',

    # Optional; auto-discovered next to cdb.exe / Debugging Tools otherwise.
    [string]$SymChkPath = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- config

$configPath = Join-Path $PSScriptRoot "hunt-proc.$Channel.config.psd1"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: channel config not found: $configPath" -ForegroundColor Red
    exit 1
}

$config = Import-PowerShellDataFile $configPath
if (-not $config.SymbolCache) {
    Write-Host "ERROR: no SymbolCache in config $configPath." -ForegroundColor Red
    exit 1
}
if (-not $config.SymbolServers) {
    Write-Host "ERROR: no SymbolServers in config $configPath." -ForegroundColor Red
    exit 1
}

# Same symbol-path assembly as hunt-proc.ps1: local cache first, then servers.
$symbolPath = (@("cache*$($config.SymbolCache)") + $config.SymbolServers) -join ';'

Write-Host "Channel: $Channel" -ForegroundColor Cyan
Write-Host "Symbol cache: $($config.SymbolCache)" -ForegroundColor Cyan

# ---------------------------------------------------------------- KiCad

if (-not (Test-Path -PathType Leaf $KicadExe)) {
    Write-Host "ERROR: KiCad binary not found at: $KicadExe" -ForegroundColor Red
    Write-Host "Pass the real path explicitly via -KicadExe (the version is not guessed)." -ForegroundColor Red
    exit 1
}

$binDir = Split-Path -Parent $KicadExe

$versionInfo = (Get-Item $KicadExe).VersionInfo
$fileVersion = $versionInfo.FileVersion
if (-not $fileVersion) { $fileVersion = $versionInfo.ProductVersion }
Write-Host "Installed KiCad: FileVersion $fileVersion (ProductVersion $($versionInfo.ProductVersion))" -ForegroundColor Cyan
Write-Host "Fetching symbols for this version from: $binDir" -ForegroundColor Cyan

# ---------------------------------------------------------------- symchk

# Same Find-Tool-style discovery as hunt-proc.ps1: explicit path wins, then
# next to cdb.exe (from the channel config), then PATH, then the typical
# Debugging Tools folders.
function Find-SymChk {
    param([string]$Explicit, [string]$CdbPath)
    if ($Explicit -and (Test-Path $Explicit)) { return $Explicit }
    if ($CdbPath -and (Test-Path $CdbPath)) {
        $nextToCdb = Join-Path (Split-Path -Parent $CdbPath) 'symchk.exe'
        if (Test-Path $nextToCdb) { return $nextToCdb }
    }
    $inPath = Get-Command symchk.exe -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    foreach ($dir in @(
        'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64',
        'C:\Program Files\Windows Kits\10\Debuggers\x64'
    )) {
        $hit = Get-ChildItem -Path $dir -Filter 'symchk.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$symchk = Find-SymChk $SymChkPath $config.CdbPath
if (-not $symchk) {
    Write-Host "ERROR: symchk.exe not found (look next to cdb.exe / Debugging Tools)." -ForegroundColor Red
    exit 1
}
Write-Host "symchk: $symchk" -ForegroundColor Cyan

# ---------------------------------------------------------------- run

# Explicit warning + confirmation BEFORE the first network request. This is a
# manual one-shot tool, so blocking on the user is fine here; hunt-proc.ps1
# must stay unattended and must NOT get a pause like this.
Write-Host ""
Write-Host "WARNING: requests will now go to $($config.SymbolServers -join ', ')" -ForegroundColor Yellow
Write-Host "Make sure there is network access to these servers." -ForegroundColor Yellow
$null = Read-Host "Press Enter when ready (or Ctrl+C to cancel)"

Write-Host ""
Write-Host "Symbol path: $symbolPath" -ForegroundColor DarkGray
Write-Host "Running symchk on folder: $binDir" -ForegroundColor Cyan

# Stream symchk output to the console as-is (manual tool, not background),
# while keeping a copy of stdout so the summary lines can be highlighted.
& $symchk /r $binDir /s $symbolPath /v | Tee-Object -Variable symchkLive
$exitCode = $LASTEXITCODE

Write-Host ""
$summary = @($symchkLive | Where-Object { $_ -match 'SYMCHK:' })
if ($summary) {
    Write-Host "symchk summary:" -ForegroundColor Cyan
    foreach ($line in $summary) { Write-Host $line }
}
if ($exitCode -eq 0) {
    Write-Host "symchk exit code: $exitCode" -ForegroundColor Green
} else {
    Write-Host "symchk exit code: $exitCode — see the SYMCHK lines above." -ForegroundColor Yellow
}
Write-Host "Done." -ForegroundColor Green
