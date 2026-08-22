# hunt-proc.ps1 (v3.5) — process death hunter (default: kicad.exe).
#
# What it does:
#   - attaches ProcDump to EVERY instance of the tracked processes
#     (ProcessNames in the config, default: kicad; new ones are picked up
#     on the fly); a dump is written on first-chance exceptions of fatal
#     codes and on process termination (a silent exit also yields a snapshot)
#   - opens dumps with cdb IN THE BACKGROUND (!analyze -v + KiCad symbol
#     stack), writes <dump>.analysis.txt and prints the verdict to the log
#   - at startup it picks up UNOPENED dumps from previous sessions (orphans
#     left behind by a killed hunter) and opens those too
#   - settings live in hunt-proc.config.psd1 next to the script;
#     precedence: command-line parameters > config > defaults
#
# Modes:
#   hunt-proc.ps1                        — hunt (main)
#   hunt-proc.ps1 -Analyze path.dmp      — manually open a single dump
#   hunt-proc.ps1 -Install / -Uninstall  — autostart as a Scheduled Task
#   hunt-proc.ps1 -Stop                  — stop a running hunter (via hunter.lock)
#
# Battle history:
#   v2   — multi-PID; procdump/cdb write to files themselves (encodings)
#   v2.1 — $pdArgs instead of $args; try/catch loop; heartbeat; lock file
#   v2.2 — analysis in background jobs (loop does not block); fresh dumps only
#   v3.0 — config file; pickup of orphan dumps at startup; -Analyze mode;
#          Full/Mini dump choice (mini fits into GitLab attachments)
#   v3.1 — ProcessNames in the config: hunt any process, not just kicad
#   v3.2 — default config name fixed to the real one (hunt-proc.config.psd1,
#          was hunt-proc_config.psd1 — underscore instead of a dot, the config
#          was silently not found); clean-termination dumps (Exit Code 0) no
#          longer go to cdb analysis and are deleted right away — ProcDump
#          itself cannot filter -t by exit code, and keeping 3+ GB for a
#          regular KiCad close is pointless
#   v3.3 — dump pickup switched from a directory glob (mtime after someone
#          else's exit) to reading EACH PID's own log (Dump N
#          initiated/complete): a half-written dump of one process no longer
#          reaches cdb because of another one finishing; added the -h trigger
#          (hung window) for GUI apps
#   v3.4 — added -Stop mode: stops the hunter by the PID from hunter.lock
#          (fixes "second run not needed" without hunting for the process)
#   v3.5 — -t (dump on ANY termination) is no longer hardcoded: now an
#          explicit DumpOnTermination flag (bool, default $false, resolved
#          CLI > config > default) so normal clean exits are not dumped at
#          all, not just deleted afterwards. Exit-0 skip logic kept as a
#          harmless no-op for when the flag is flipped back on.

[CmdletBinding()]
param(
    [string]$Analyze = "",
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Stop,
    # Everything below can be set in the config; a parameter overrides the config
    [string]$ConfigPath = "",
    [string]$DumpDir = "",
    [string]$SymbolCache = "",
    [string]$ProcDumpPath = "",
    [string]$CdbPath = "",
    [string[]]$ExceptionFilters = $null,
    [int]$MaxDumpsPerAttach = -1,
    [string]$DumpType = "",          # Full | Mini
    [Nullable[bool]]$DumpOnTermination = $null,  # dump on ANY termination, not just crashes/hangs
    [int]$OrphanMaxAgeHours = -1,
    [string[]]$ProcessNames = $null  # process names WITHOUT .exe, e.g. kicad,freecad
)

$ErrorActionPreference = "Stop"
$TaskName = "ProcDumpHunter"

# ---------------------------------------------------------------- config

$defaults = @{
    ProcessNames      = @("kicad")
    DumpDir           = "D:\Projects\WinDbg\KiCad"
    SymbolCache       = "C:\SymbolsCache"
    ProcDumpPath      = ""
    CdbPath           = ""
    ExceptionFilters  = @("C0000005", "C0000409", "80000003")
    MaxDumpsPerAttach = 5
    DumpOnTermination  = $false     # dump on ANY termination, incl. clean exit; off by default —
                                    # right now we only want crashes/hangs, not normal closes
    DumpType          = "Full"      # Full: -ma (gigabytes, whole memory)
                                    # Mini: -mp (tens of MB, stacks+registers —
                                    #       fits into a GitLab attachment)
    OrphanMaxAgeHours = 24          # orphan dumps older than this — leave alone
    SymbolServers     = @(
        "srv*https://msdl.microsoft.com/download/symbols",
        "srv*https://symbols.kicad.org/kicad-stable"
    )
}

if (-not (Test-Path $ConfigPath)) {
    Write-Host "WARNING: config $ConfigPath not found — running on defaults" -ForegroundColor Yellow
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "hunt-proc.config.psd1" }
$config = @{}
if (Test-Path $ConfigPath) {
    try { $config = Import-PowerShellDataFile $ConfigPath }
    catch { Write-Host "WARNING: config $ConfigPath cannot be read: $($_.Exception.Message)" }
}

function Resolve-Setting($cliValue, $key, $emptyValue) {
    # precedence: CLI > config > default. $emptyValue marks "CLI not set"
    if ($null -ne $cliValue -and "$cliValue" -ne "$emptyValue") { return $cliValue }
    if ($config.ContainsKey($key)) { return $config[$key] }
    return $defaults[$key]
}

$DumpDir           = Resolve-Setting $DumpDir           'DumpDir'           ""
$SymbolCache       = Resolve-Setting $SymbolCache       'SymbolCache'       ""
$ProcDumpPath      = Resolve-Setting $ProcDumpPath      'ProcDumpPath'      ""
$CdbPath           = Resolve-Setting $CdbPath           'CdbPath'           ""
$ExceptionFilters  = Resolve-Setting $ExceptionFilters  'ExceptionFilters'  $null
$MaxDumpsPerAttach = Resolve-Setting $MaxDumpsPerAttach 'MaxDumpsPerAttach' -1
$DumpType          = Resolve-Setting $DumpType          'DumpType'          ""
$OrphanMaxAgeHours = Resolve-Setting $OrphanMaxAgeHours 'OrphanMaxAgeHours' -1
$ProcessNames      = Resolve-Setting $ProcessNames      'ProcessNames'      $null
# bool needs $null to mean "not set" ($false is a valid value), so it cannot
# go through Resolve-Setting's string sentinel — resolve it explicitly.
$DumpOnTermination = if ($null -ne $DumpOnTermination) { $DumpOnTermination }
                     elseif ($config.ContainsKey('DumpOnTermination')) { [bool]$config.DumpOnTermination }
                     else { $defaults.DumpOnTermination }
$symbolServers     = if ($config.ContainsKey('SymbolServers')) { $config.SymbolServers }
                     else { $defaults.SymbolServers }

$SymbolPath = (@("cache*$SymbolCache") + $symbolServers) -join ";"
$dumpTypeArg = if ($DumpType -eq "Mini") { "-mp" } else { "-ma" }

# ---------------------------------------------------------------- helpers

function Log($msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    Write-Host $line
    Add-Content -Path (Join-Path $DumpDir "hunter.log") -Value $line -Encoding UTF8
}

function Find-Tool($explicit, $name, $candidates) {
    if ($explicit -and (Test-Path $explicit)) { return $explicit }
    $inPath = Get-Command $name -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    foreach ($c in $candidates) {
        $hit = Get-ChildItem -Path $c -Filter $name -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# ---------------------------------------------------------------- install

if ($Install) {
    $self = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -RunLevel Highest -Force | Out-Null
    Write-Host "Task '$TaskName' created (settings will be read from the config)."
    return
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Task '$TaskName' removed."
    return
}

# ---------------------------------------------------------------- stop

if ($Stop) {
    $lockFile = Join-Path $DumpDir "hunter.lock"
    if (-not (Test-Path $lockFile)) {
        Write-Host "Lock file not found — the hunter does not seem to be running."
        return
    }
    $oldPid = Get-Content $lockFile -ErrorAction SilentlyContinue
    $proc = if ($oldPid) { Get-Process -Id $oldPid -ErrorAction SilentlyContinue } else { $null }
    if (-not $proc) {
        Write-Host "PID $oldPid from the lock file no longer exists, just removing the lock file."
        Remove-Item $lockFile -Force
        return
    }
    try {
        Stop-Process -Id $oldPid -Force -ErrorAction Stop
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        Write-Host "Hunter (PID $oldPid) stopped."
    } catch {
        Write-Host "Failed to stop PID $oldPid`: $($_.Exception.Message)"
        Write-Host "If the hunter runs in an elevated window, stop it from there (run -Stop as administrator)."
    }
    return
}

# ---------------------------------------------------------------- tools

New-Item -ItemType Directory -Force -Path $DumpDir, $SymbolCache | Out-Null

$procdump = Find-Tool $ProcDumpPath "procdump.exe" @(
    "D:\Utils", "$env:USERPROFILE\Downloads", "C:\Tools", "C:\Sysinternals", "D:\Tools")
$cdb = Find-Tool $CdbPath "cdb.exe" @(
    "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64",
    "C:\Program Files\Windows Kits\10\Debuggers\x64")
$env:_NT_SYMBOL_PATH = $SymbolPath

# ---------------------------------------------------------------- analysis

function Invoke-CdbAnalysis($dmp) {
    # Synchronous opening: cdb writes the file itself, encodings untouched
    $outFile = "$dmp.analysis.txt"
    $cmd = "`"$cdb`" -z `"$dmp`" -c `"!analyze -v; .ecxr; kb; q`" > `"$outFile`" 2>&1"
    cmd /c $cmd | Out-Null
    return $outFile
}

function Report-Analysis($dmp) {
    $outFile = "$dmp.analysis.txt"
    $txt = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    if (-not $txt) { Log "  empty analysis: $([IO.Path]::GetFileName($dmp))"; return }
    $bucket  = [regex]::Match($txt, 'FAILURE_BUCKET_ID:\s*(\S+)').Groups[1].Value
    $comment = [regex]::Match($txt, '(?m)^\*\*\* (.+)$').Groups[1].Value
    $frames  = [regex]::Matches($txt, '(?m)^[0-9a-f`]+ [0-9a-f`]+\s+: (?:[0-9a-f` ]+: )?(\S+?)(\+0x[0-9a-fA-F]+)?\s*$') |
               Select-Object -First 8 | ForEach-Object { $_.Groups[1].Value }
    Log "=== VERDICT: $([IO.Path]::GetFileName($dmp)) ==="
    if ($comment) { Log "  trigger: $comment" }
    Log "  bucket: $(if ($bucket) {$bucket} else {'<not found>'})"
    foreach ($f in ($frames | Select-Object -Unique)) { Log "  frame:  $f" }
    Log "  full analysis: $outFile"
}

# ---- manual analysis mode ----
if ($Analyze) {
    if (-not (Test-Path $Analyze)) { Write-Host "Dump not found: $Analyze"; return }
    if (-not $cdb) { Write-Host "cdb.exe not found — nothing to open dumps with."; return }
    Write-Host "Opening $Analyze (symbols: $SymbolPath)..."
    Invoke-CdbAnalysis $Analyze | Out-Null
    Report-Analysis $Analyze
    return
}

# ---------------------------------------------------------------- guard

if (-not $procdump) {
    Log "procdump.exe not found. https://learn.microsoft.com/sysinternals/downloads/procdump"
    return
}
if (-not $cdb) {
    Log "cdb.exe not found (Windows SDK -> Debugging Tools) — dumps WITHOUT auto-analysis."
}

$lockFile = Join-Path $DumpDir "hunter.lock"
if (Test-Path $lockFile) {
    $oldPid = Get-Content $lockFile -ErrorAction SilentlyContinue
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        Write-Host "Hunter already running (PID $oldPid). No second one needed."
        return
    }
}
Set-Content -Path $lockFile -Value $PID

Log "hunt-proc v3.5 started (PID $PID). config: $(if (Test-Path $ConfigPath) {$ConfigPath} else {'<none, defaults>'})"
Log "procdump: $procdump; cdb: $(if ($cdb) {$cdb} else {'none'}); dump type: $DumpType ($dumpTypeArg)"
Log "processes: $($ProcessNames -join ', '); filters: $($ExceptionFilters -join ', '); dump-on-termination: $DumpOnTermination; dumps: $DumpDir"

# ---------------------------------------------------------------- jobs

$analysisJobs = @{}

function Start-DumpAnalysis($dmp) {
    if (-not $cdb) { return }
    Log "analysis (background): $([IO.Path]::GetFileName($dmp))..."
    $analysisJobs[$dmp] = Start-Job -ScriptBlock {
        param($cdbPath, $dumpPath, $outPath, $symPath)
        $env:_NT_SYMBOL_PATH = $symPath
        cmd /c "`"$cdbPath`" -z `"$dumpPath`" -c `"!analyze -v; .ecxr; kb; q`" > `"$outPath`" 2>&1"
    } -ArgumentList $cdb, $dmp, "$dmp.analysis.txt", $SymbolPath
}

# ---- orphan dumps from previous sessions ----
$orphans = Get-ChildItem $DumpDir -Filter "*.dmp" -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$OrphanMaxAgeHours) -and
                          -not (Test-Path "$($_.FullName).analysis.txt") } |
           Sort-Object LastWriteTime
if ($orphans) {
    Log "unopened dumps from previous sessions found: $($orphans.Count) — sending for analysis"
    foreach ($d in $orphans) { Start-DumpAnalysis $d.FullName }
}

# ---------------------------------------------------------------- hunt loop

$hunted = @{}    # pid -> @{ Proc; Log; Name }
$submitted = @{} # dump path -> $true — already sent for analysis (do not parse twice)
$filterArgs = @()
foreach ($f in $ExceptionFilters) { $filterArgs += @("-f", $f) }

$lastBeat = Get-Date
while ($true) {
  try {
    if ((Get-Date) - $lastBeat -gt [TimeSpan]::FromMinutes(5)) {
        Log "heartbeat: alive; under watch PID: $(if ($hunted.Count) {$hunted.Keys -join ', '} else {'none'})"
        $lastBeat = Get-Date
    }

    # 1. Attach to all instances of the tracked processes not yet under watch
    $procs = @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)
    foreach ($proc0 in $procs) {
        $p = $proc0.Id
        if ($hunted.ContainsKey($p)) { continue }
        $pName = $proc0.ProcessName
        $pdLog = Join-Path $DumpDir "procdump_${pName}_$p.txt"
        # -e/-h: first-chance exceptions, hung window (-h — the same mechanism
        # Windows uses to report "Not responding"). -t (dump on ANY termination)
        # is conditional: only when $DumpOnTermination is $true, otherwise a
        # clean exit would write gigabytes for nothing.
        $pdArgs = @("-accepteula", $dumpTypeArg, "-e", "1") + $filterArgs + @("-h")
        if ($DumpOnTermination) { $pdArgs += "-t" }
        $pdArgs += @("-n", $MaxDumpsPerAttach, $p, $DumpDir)
        $proc = Start-Process -FilePath $procdump -ArgumentList $pdArgs `
                -NoNewWindow -PassThru -RedirectStandardOutput $pdLog
        $hunted[$p] = @{ Proc = $proc; Log = $pdLog; Name = $pName }
        Log "attached to $pName.exe PID $p (procdump PID $($proc.Id))"
    }

    # 2. Which procdumps exited — show the log tail and count the dumps from a
    #    CLEAN termination (Exit Code 0) that must not go to cdb.
    $done = @($hunted.Keys | Where-Object { $hunted[$_].Proc.HasExited })
    $skipDumps = @{}   # path -> $true — dumps from clean termination (Exit 0), do not analyze
    foreach ($p in $done) {
        Log "procdump for $($hunted[$p].Name).exe PID $p detached"
        $logLines = @(Get-Content $hunted[$p].Log -Encoding Unicode -ErrorAction SilentlyContinue)
        $tail = $logLines |
                Where-Object { $_ -match 'Dump \d+ (initiated|complete)|Terminated|Exception|Process Exit|Unhandled' } |
                Select-Object -Last 8
        foreach ($t in $tail) { Log "  procdump[$($hunted[$p].Name):$p]: $($t.Trim())" }

        # ProcDump itself cannot filter -t by exit code (checked with -?,
        # there is no such flag) — it still writes the dump to disk. But if
        # the termination is clean (Exit Code 0x00000000 — a normal app
        # close, not a crash), the dump is useless for a BugReport: mark it
        # for deletion WITHOUT handing it to cdb, saving both space and the
        # ~minute of analysis. Dumps from REAL exceptions in this same
        # session (Dump N initiated BEFORE the Process Exit line) are left
        # alone — we only count the "Dump N initiated" lines that come AFTER
        # the clean-exit line.
        $exitMatch = $logLines | Select-String 'Process Exit: PID \d+, Exit Code 0x00000000' |
                     Select-Object -First 1
        if ($exitMatch) {
            $logLines | Select-String 'Dump \d+ initiated:\s*(.+\.dmp)' |
                Where-Object { $_.LineNumber -gt $exitMatch.LineNumber } |
                ForEach-Object { $skipDumps[$_.Matches[0].Groups[1].Value.Trim()] = $true }
        }
    }

    # 3. Parse the dumps of EVERY tracked PID (including the just-detached
    #    ones — they are still in $hunted on this iteration) from its OWN
    #    log, not from a directory-wide glob by mtime. The old glob
    #    (Start-Sleep 2 + Get-ChildItem $DumpDir by mtime) only fired on
    #    SOMEONE's exit and could catch a half-written dump of ANOTHER,
    #    still-alive process (2026-08-21: cdb opened
    #    kicad.exe_260821_210426.dmp mid-write). The path comes from the
    #    "Dump N initiated: <path>" line, file readiness from "Dump N
    #    complete"; match by dump number N.
    foreach ($p in @($hunted.Keys)) {
        $logLines = @(Get-Content $hunted[$p].Log -Encoding Unicode -ErrorAction SilentlyContinue)
        $initiated = @{}   # N -> dump path from "Dump N initiated: <path>" lines
        $logLines | Select-String 'Dump (\d+) initiated:\s*(.+\.dmp)' | ForEach-Object {
            $initiated[$_.Matches[0].Groups[1].Value] = $_.Matches[0].Groups[2].Value.Trim()
        }
        $completeNums = @($logLines | Select-String 'Dump (\d+) complete' |
                          ForEach-Object { $_.Matches[0].Groups[1].Value })
        foreach ($n in $completeNums) {
            if (-not $initiated.ContainsKey($n)) { continue }
            $path = $initiated[$n]
            if ($submitted.ContainsKey($path) -or $analysisJobs.ContainsKey($path)) { continue }
            if ($skipDumps.ContainsKey($path)) {
                Log "  clean termination (Exit 0) — dump without analysis, deleting: $([IO.Path]::GetFileName($path))"
                Remove-Item $path -Force -ErrorAction SilentlyContinue
                continue
            }
            $submitted[$path] = $true
            Start-DumpAnalysis $path
        }
    }

    # 4. Remove the detached ones from the bookkeeping (whom to keep trying to
    #    re-attach). Remove AFTER step 3: their last dump by -t is already in
    #    the log and must make it to analysis.
    foreach ($p in $done) { $hunted.Remove($p) }

    # 5. Collect finished background analyses
    $finished = @($analysisJobs.Keys | Where-Object { $analysisJobs[$_].State -ne 'Running' })
    foreach ($dmp in $finished) {
        Receive-Job $analysisJobs[$dmp] -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $analysisJobs[$dmp] -Force -ErrorAction SilentlyContinue
        $analysisJobs.Remove($dmp)
        Report-Analysis $dmp
    }
  } catch {
        Log "LOOP ERROR (hunter keeps running): $($_.Exception.Message)"
  }
    Start-Sleep -Seconds 3
}
