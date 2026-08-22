# test_dump_pickup.ps1 -- regression test for hunt-proc.ps1 v3.5 dump pickup / flags.
#
# Covers (see techdocs/handoff_2026_08_22_hang_trigger_and_dump_race_fix.md, Part 1,
# and techdocs/handoff_2026_08_22_dump_on_termination_flag.md):
#   1. A dump that has "Dump N initiated" but no "Dump N complete" yet (file is
#      still being written by a live procdump) must NOT be submitted for analysis.
#   2. A dump with both lines (initiated + complete) must be submitted.
#   3. $submitted must prevent submitting the same dump twice.
#   4. (Part 2) "-h" must be present in the $pdArgs assembly in hunt-proc.ps1.
#   5. (Part 3) "-t" is conditional on $DumpOnTermination: absent by default,
#      present only when the flag is $true.
#
# The algorithm below mirrors the "3. Parse dumps of EVERY tracked PID" section
# of hunt-proc.ps1 (map "Dump N initiated: <path>" -> {N: path}; "Dump N
# complete" confirms the file is ready; match by dump number N). No real
# procdump/cdb is needed:
#   powershell -NoProfile -File .\diagnostics\test_dump_pickup.ps1

$ErrorActionPreference = "Stop"

# Mirror of the hunt-proc.ps1 algorithm (no side effects): return the paths of
# completed dumps from one procdump log that are not yet in $submitted.
function Get-CompletedDumpPaths($logLines, $submitted) {
    $initiated = @{}   # N -> path from "Dump N initiated: <path>" lines
    $logLines | Select-String 'Dump (\d+) initiated:\s*(.+\.dmp)' | ForEach-Object {
        $initiated[$_.Matches[0].Groups[1].Value] = $_.Matches[0].Groups[2].Value.Trim()
    }
    $out = @()
    $logLines | Select-String 'Dump (\d+) complete' | ForEach-Object {
        $n = $_.Matches[0].Groups[1].Value
        if ($initiated.ContainsKey($n)) {
            $path = $initiated[$n]
            if (-not $submitted.ContainsKey($path)) { $out += $path }
        }
    }
    return $out
}

$script:failed = 0
function Assert-Equal($actual, $expected, $label) {
    $a = @($actual | ForEach-Object { [string]$_ }) -join "|"
    $e = @($expected | ForEach-Object { [string]$_ }) -join "|"
    if ($a -ne $e) {
        $script:failed++
        Write-Host "FAIL: $label" -ForegroundColor Red
        Write-Host "  expected: [$e]"
        Write-Host "  actual:   [$a]"
    } else {
        Write-Host "PASS: $label" -ForegroundColor Green
    }
}

# ---- Test 1: incomplete dump (no 'Dump N complete') is NOT submitted
$logIncomplete = @(
    "[16:07:11]Dump 1 initiated: D:\tmp\kicad.exe_A.dmp",
    "[16:07:11]Dump 1 writing: Estimated dump file size is 3423 MB."
    # no "Dump 1 complete" -- file still being written by a live procdump
)
$submitted = @{}
$got = @(Get-CompletedDumpPaths $logIncomplete $submitted)
Assert-Equal $got @() "incomplete dump (no 'Dump N complete') is NOT submitted"

# ---- Test 2: completed dump (initiated + complete) IS submitted
$logComplete = @(
    "[16:07:11]Dump 1 initiated: D:\tmp\kicad.exe_B.dmp",
    "[16:07:11]Dump 1 writing: Estimated dump file size is 3423 MB.",
    "[16:07:59]Dump 1 complete: 3425 MB written in 47.8 seconds"
)
$got = @(Get-CompletedDumpPaths $logComplete $submitted)
Assert-Equal $got @("D:\tmp\kicad.exe_B.dmp") "completed dump (initiated + complete) IS submitted"
# mimic hunt-proc.ps1: `$submitted[$path] = $true` right after Start-DumpAnalysis
$submitted["D:\tmp\kicad.exe_B.dmp"] = $true

# ---- Test 3: $submitted prevents re-submission
$got = @(Get-CompletedDumpPaths $logComplete $submitted)
Assert-Equal $got @() "re-pass with same `$submitted returns nothing"

# ---- Test 4: mixed log, only the completed dump is submitted
$logMixed = @(
    "[16:07:11]Dump 1 initiated: D:\tmp\kicad.exe_C.dmp",
    "[16:07:11]Dump 2 initiated: D:\tmp\kicad.exe_C2.dmp",   # still writing
    "[16:07:59]Dump 1 complete: 3425 MB written in 47.8 seconds"
)
$got = @(Get-CompletedDumpPaths $logMixed $submitted)
Assert-Equal $got @("D:\tmp\kicad.exe_C.dmp") "from a mixed log only the completed dump is submitted"

# ---- Test 5 (Part 2 + Part 3): '-h' present AND '-t' conditional in $pdArgs
$src = Get-Content (Join-Path $PSScriptRoot "..\hunt-proc.ps1") -Raw
$hasH = [regex]::IsMatch(
    $src,
    '(?m)\$pdArgs\s*=\s*@\("-accepteula",\s*\$dumpTypeArg,\s*"-e",\s*"1"\)\s*\+\s*\$filterArgs\s*\+\s*@\("-h"\)'
)
$hasConditionalT = [regex]::IsMatch(
    $src,
    '(?m)if\s*\(\$DumpOnTermination\)\s*\{\s*\$pdArgs\s*\+=\s*"-t"\s*\}'
)
if ($hasH -and $hasConditionalT) {
    Write-Host "PASS: '-h' present and '-t' conditional on `$DumpOnTermination in `$pdArgs" -ForegroundColor Green
} else {
    $script:failed++
    Write-Host "FAIL: '-h'/conditional '-t' not found in `$pdArgs assembly (hasH=$hasH, conditionalT=$hasConditionalT)" -ForegroundColor Red
}

# ---- Test 6 (Part 3): modeled $pdArgs assembly — -t off by default, on when requested
function Build-PdArgs($DumpOnTermination) {
    # mirrors the hunt-proc.ps1 $pdArgs assembly for one attach
    $filterArgs = @("-f", "C0000005")
    $pdArgs = @("-accepteula", "-ma", "-e", "1") + $filterArgs + @("-h")
    if ($DumpOnTermination) { $pdArgs += "-t" }
    $pdArgs += @("-n", 5, 1234, "D:\tmp")
    return $pdArgs
}
$off = @(Build-PdArgs $false)
$on  = @(Build-PdArgs $true)
if ($off -notcontains "-t" -and $on -contains "-t") {
    Write-Host "PASS: -t absent when `$DumpOnTermination=`$false, present when `$true" -ForegroundColor Green
} else {
    $script:failed++
    Write-Host "FAIL: -t not conditional on `$DumpOnTermination (off has -t: $($off -contains '-t'), on has -t: $($on -contains '-t'))" -ForegroundColor Red
}

Write-Host ""
if ($script:failed -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "$script:failed test(s) FAILED" -ForegroundColor Red
    exit 1
}
