# hunt-proc.ps1 (v3.3) — охотник за смертями процессов (по умолчанию kicad.exe).
#
# Что умеет:
#   - цепляет ProcDump к КАЖДОМУ инстансу отслеживаемых процессов
#     (ProcessNames в конфиге, по умолчанию kicad; новые — на лету);
#     дамп пишется на first-chance исключениях фатальных кодов и на
#     завершении процесса (тихий выход тоже даёт снимок)
#   - вскрывает дампы cdb'ом В ФОНЕ (!analyze -v + стек с символами KiCad),
#     кладёт <дамп>.analysis.txt и печатает вердикт в лог
#   - при старте подбирает НЕВСКРЫТЫЕ дампы прошлых сессий (сироты после
#     убитого охотника) и вскрывает их тоже
#   - настройки в hunt-proc.config.psd1 рядом со скриптом;
#     приоритет: параметры командной строки > конфиг > дефолты
#
# Режимы:
#   hunt-proc.ps1                        — охота (основной)
#   hunt-proc.ps1 -Analyze путь.dmp      — ручное вскрытие одного дампа
#   hunt-proc.ps1 -Install / -Uninstall  — автостарт как Scheduled Task
#
# История боевых правок:
#   v2   — мульти-PID; procdump/cdb пишут в файлы сами (кодировки)
#   v2.1 — $pdArgs вместо $args; try/catch цикла; heartbeat; lock-файл
#   v2.2 — анализ в фоновых job'ах (цикл не слепнет); только свежие дампы
#   v3.0 — конфиг-файл; подбор дампов-сирот при старте; режим -Analyze;
#          выбор Full/Mini дампов (мини влезают во вложения GitLab)
#   v3.1 — ProcessNames в конфиге: охота на любые процессы, не только kicad
#   v3.2 — дефолтное имя конфига поправлено на реальное (hunt-proc.config.psd1,
#          было hunt-proc_config.psd1 — подчёркивание вместо точки, конфиг
#          молча не находился); дампы чистого завершения (Exit Code 0) больше
#          не идут на cdb-анализ и сразу удаляются — ProcDump сам не умеет
#          фильтровать -t по коду выхода, но держать 3+ ГБ ради обычного
#          закрытия KiCad незачем
#   v3.3 — разбор дампов переведён с глоба по папке (mtime после чьего-то exit)
#          на чтение СОБСТВЕННОГО лога каждого PID (Dump N initiated/complete):
#          недописанный дамп одного процесса больше не уходит в cdb из-за
#          чужого завершения; добавлен триггер -h (зависшее окно) для GUI

[CmdletBinding()]
param(
    [string]$Analyze = "",
    [switch]$Install,
    [switch]$Uninstall,
    # Всё ниже можно задать в конфиге; параметр перекрывает конфиг
    [string]$ConfigPath = "",
    [string]$DumpDir = "",
    [string]$SymbolCache = "",
    [string]$ProcDumpPath = "",
    [string]$CdbPath = "",
    [string[]]$ExceptionFilters = $null,
    [int]$MaxDumpsPerAttach = -1,
    [string]$DumpType = "",          # Full | Mini
    [int]$OrphanMaxAgeHours = -1,
    [string[]]$ProcessNames = $null  # имена процессов БЕЗ .exe, напр. kicad,freecad
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
    DumpType          = "Full"      # Full: -ma (гигабайты, вся память)
                                    # Mini: -mp (десятки МБ, стеки+регистры —
                                    #       влезает во вложение GitLab)
    OrphanMaxAgeHours = 24          # дампы-сироты старше — не трогаем
    SymbolServers     = @(
        "srv*https://msdl.microsoft.com/download/symbols",
        "srv*https://symbols.kicad.org/kicad-stable"
    )
}

if (-not (Test-Path $ConfigPath)) {
    Write-Host "ВНИМАНИЕ: конфиг $ConfigPath не найден — работаю на дефолтах" -ForegroundColor Yellow
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "hunt-proc.config.psd1" }
$config = @{}
if (Test-Path $ConfigPath) {
    try { $config = Import-PowerShellDataFile $ConfigPath }
    catch { Write-Host "ВНИМАНИЕ: конфиг $ConfigPath не читается: $($_.Exception.Message)" }
}

function Resolve-Setting($cliValue, $key, $emptyValue) {
    # приоритет: CLI > конфиг > дефолт. $emptyValue — признак "CLI не задан"
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
    Write-Host "Задача '$TaskName' создана (настройки возьмутся из конфига)."
    return
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Задача '$TaskName' удалена."
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
    # Синхронное вскрытие: cdb пишет в файл сам, кодировки не трогаем
    $outFile = "$dmp.analysis.txt"
    $cmd = "`"$cdb`" -z `"$dmp`" -c `"!analyze -v; .ecxr; kb; q`" > `"$outFile`" 2>&1"
    cmd /c $cmd | Out-Null
    return $outFile
}

function Report-Analysis($dmp) {
    $outFile = "$dmp.analysis.txt"
    $txt = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    if (-not $txt) { Log "  анализ пуст: $([IO.Path]::GetFileName($dmp))"; return }
    $bucket  = [regex]::Match($txt, 'FAILURE_BUCKET_ID:\s*(\S+)').Groups[1].Value
    $comment = [regex]::Match($txt, '(?m)^\*\*\* (.+)$').Groups[1].Value
    $frames  = [regex]::Matches($txt, '(?m)^[0-9a-f`]+ [0-9a-f`]+\s+: (?:[0-9a-f` ]+: )?(\S+?)(\+0x[0-9a-fA-F]+)?\s*$') |
               Select-Object -First 8 | ForEach-Object { $_.Groups[1].Value }
    Log "=== ВЕРДИКТ: $([IO.Path]::GetFileName($dmp)) ==="
    if ($comment) { Log "  триггер: $comment" }
    Log "  bucket: $(if ($bucket) {$bucket} else {'<не найден>'})"
    foreach ($f in ($frames | Select-Object -Unique)) { Log "  frame:  $f" }
    Log "  полный разбор: $outFile"
}

# ---- режим ручного вскрытия ----
if ($Analyze) {
    if (-not (Test-Path $Analyze)) { Write-Host "Дамп не найден: $Analyze"; return }
    if (-not $cdb) { Write-Host "cdb.exe не найден — вскрывать нечем."; return }
    Write-Host "Вскрываю $Analyze (символы: $SymbolPath)..."
    Invoke-CdbAnalysis $Analyze | Out-Null
    Report-Analysis $Analyze
    return
}

# ---------------------------------------------------------------- guard

if (-not $procdump) {
    Log "procdump.exe не найден. https://learn.microsoft.com/sysinternals/downloads/procdump"
    return
}
if (-not $cdb) {
    Log "cdb.exe не найден (Windows SDK -> Debugging Tools) — дампы БЕЗ автоанализа."
}

$lockFile = Join-Path $DumpDir "hunter.lock"
if (Test-Path $lockFile) {
    $oldPid = Get-Content $lockFile -ErrorAction SilentlyContinue
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        Write-Host "Охотник уже работает (PID $oldPid). Второй не нужен."
        return
    }
}
Set-Content -Path $lockFile -Value $PID

Log "hunt-proc v3.3 запущен (PID $PID). конфиг: $(if (Test-Path $ConfigPath) {$ConfigPath} else {'<нет, дефолты>'})"
Log "procdump: $procdump; cdb: $(if ($cdb) {$cdb} else {'нет'}); тип дампов: $DumpType ($dumpTypeArg)"
Log "процессы: $($ProcessNames -join ', '); фильтры: $($ExceptionFilters -join ', '); дампы: $DumpDir"

# ---------------------------------------------------------------- jobs

$analysisJobs = @{}

function Start-DumpAnalysis($dmp) {
    if (-not $cdb) { return }
    Log "анализ (в фоне): $([IO.Path]::GetFileName($dmp))..."
    $analysisJobs[$dmp] = Start-Job -ScriptBlock {
        param($cdbPath, $dumpPath, $outPath, $symPath)
        $env:_NT_SYMBOL_PATH = $symPath
        cmd /c "`"$cdbPath`" -z `"$dumpPath`" -c `"!analyze -v; .ecxr; kb; q`" > `"$outPath`" 2>&1"
    } -ArgumentList $cdb, $dmp, "$dmp.analysis.txt", $SymbolPath
}

# ---- дампы-сироты прошлых сессий ----
$orphans = Get-ChildItem $DumpDir -Filter "*.dmp" -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$OrphanMaxAgeHours) -and
                          -not (Test-Path "$($_.FullName).analysis.txt") } |
           Sort-Object LastWriteTime
if ($orphans) {
    Log "найдено невскрытых дампов прошлых сессий: $($orphans.Count) — отправляю на вскрытие"
    foreach ($d in $orphans) { Start-DumpAnalysis $d.FullName }
}

# ---------------------------------------------------------------- hunt loop

$hunted = @{}    # pid -> @{ Proc; Log; Name }
$submitted = @{} # путь дампа -> $true — уже отправлен на анализ (не разбираем дважды)
$filterArgs = @()
foreach ($f in $ExceptionFilters) { $filterArgs += @("-f", $f) }

$lastBeat = Get-Date
while ($true) {
  try {
    if ((Get-Date) - $lastBeat -gt [TimeSpan]::FromMinutes(5)) {
        Log "heartbeat: жив; под колпаком PID: $(if ($hunted.Count) {$hunted.Keys -join ', '} else {'никого'})"
        $lastBeat = Get-Date
    }

    # 1. Подцепить все инстансы отслеживаемых процессов, которые ещё не под колпаком
    $procs = @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)
    foreach ($proc0 in $procs) {
        $p = $proc0.Id
        if ($hunted.ContainsKey($p)) { continue }
        $pName = $proc0.ProcessName
        $pdLog = Join-Path $DumpDir "procdump_${pName}_$p.txt"
        # -e/-t/-h: first-chance исключения, завершение процесса, зависшее
        # окно (-h — тот же механизм, которым Windows видит "Не отвечает").
        $pdArgs = @("-accepteula", $dumpTypeArg, "-e", "1") + $filterArgs +
                  @("-h", "-t", "-n", $MaxDumpsPerAttach, $p, $DumpDir)
        $proc = Start-Process -FilePath $procdump -ArgumentList $pdArgs `
                -NoNewWindow -PassThru -RedirectStandardOutput $pdLog
        $hunted[$p] = @{ Proc = $proc; Log = $pdLog; Name = $pName }
        Log "прицепился к $pName.exe PID $p (procdump PID $($proc.Id))"
    }

    # 2. Кто из procdump'ов завершился — показать хвост лога и подсчитать
    #    дампы от ЧИСТОГО завершения (Exit Code 0), которые не идут в cdb.
    $done = @($hunted.Keys | Where-Object { $hunted[$_].Proc.HasExited })
    $skipDumps = @{}   # путь -> $true — дампы от чистого завершения (Exit 0), не анализируем
    foreach ($p in $done) {
        Log "procdump для $($hunted[$p].Name).exe PID $p отцепился"
        $logLines = @(Get-Content $hunted[$p].Log -Encoding Unicode -ErrorAction SilentlyContinue)
        $tail = $logLines |
                Where-Object { $_ -match 'Dump \d+ (initiated|complete)|Terminated|Exception|Process Exit|Unhandled' } |
                Select-Object -Last 8
        foreach ($t in $tail) { Log "  procdump[$($hunted[$p].Name):$p]: $($t.Trim())" }

        # ProcDump сам не умеет фильтровать -t по коду выхода (проверено -?,
        # такого флага нет) — дамп на диск он всё равно пишет. Но если
        # завершение чистое (Exit Code 0x00000000 — обычное закрытие
        # приложения, не крash), сам дамп бесполезен для BugReport: помечаем
        # на удаление БЕЗ передачи в cdb, экономя и место, и ~минуту анализа.
        # Дампы от РЕАЛЬНЫХ исключений в этой же сессии (Dump N initiated ДО
        # строки Process Exit) не трогаем — считаем только те "Dump N
        # initiated", что идут ПОСЛЕ строки чистого выхода.
        $exitMatch = $logLines | Select-String 'Process Exit: PID \d+, Exit Code 0x00000000' |
                     Select-Object -First 1
        if ($exitMatch) {
            $logLines | Select-String 'Dump \d+ initiated:\s*(.+\.dmp)' |
                Where-Object { $_.LineNumber -gt $exitMatch.LineNumber } |
                ForEach-Object { $skipDumps[$_.Matches[0].Groups[1].Value.Trim()] = $true }
        }
    }

    # 3. Разбор дампов КАЖДОГО подколпачного PID (включая только что
    #    отцепившихся — они ещё в $hunted на этой итерации) по ЕГО
    #    СОБСТВЕННОМУ логу, а не по глобу всей папки по времени изменения.
    #    Старый глоб (Start-Sleep 2 + Get-ChildItem $DumpDir по mtime)
    #    срабатывал только при ЧЬЁМ-ТО exit и мог поймать недописанный дамп
    #    ДРУГОГО, ещё живого процесса (2026-08-21: cdb открыл
    #    kicad.exe_260821_210426.dmp на середине записи). Путь даёт строка
    #    "Dump N initiated: <path>", готовность файла — "Dump N complete";
    #    сопоставляем по номеру N.
    foreach ($p in @($hunted.Keys)) {
        $logLines = @(Get-Content $hunted[$p].Log -Encoding Unicode -ErrorAction SilentlyContinue)
        $initiated = @{}   # N -> путь дампа из строк "Dump N initiated: <path>"
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
                Log "  чистое завершение (Exit 0) — дамп без анализа, удаляю: $([IO.Path]::GetFileName($path))"
                Remove-Item $path -Force -ErrorAction SilentlyContinue
                continue
            }
            $submitted[$path] = $true
            Start-DumpAnalysis $path
        }
    }

    # 4. Убрать отцепившихся из бухгалтерии (кого продолжать пытаться
    #    подцепить заново). Удаляем ПОСЛЕ шага 3: их последний дамп по -t уже
    #    в логе и должен успеть уйти на анализ.
    foreach ($p in $done) { $hunted.Remove($p) }

    # 5. Собрать готовые фоновые вскрытия
    $finished = @($analysisJobs.Keys | Where-Object { $analysisJobs[$_].State -ne 'Running' })
    foreach ($dmp in $finished) {
        Receive-Job $analysisJobs[$dmp] -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $analysisJobs[$dmp] -Force -ErrorAction SilentlyContinue
        $analysisJobs.Remove($dmp)
        Report-Analysis $dmp
    }
  } catch {
        Log "ОШИБКА ЦИКЛА (охотник продолжает): $($_.Exception.Message)"
  }
    Start-Sleep -Seconds 3
}