# hunt-proc_config.psd1 — настройки охотника hunt-proc.ps1 (лежит рядом со скриптом).
# Приоритет: параметры командной строки > этот файл > дефолты скрипта.
# Формат .psd1 — родной для PowerShell, никаких зависимостей.
@{
    # Какие процессы караулить (имена БЕЗ .exe). Можно несколько:
    # ProcessNames = @('kicad', 'freecad', 'librepcb')
    ProcessNames      = @('kicad')

    # Куда складывать дампы, hunter.log и procdump_*.txt
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # Локальный кэш символов (общий для Microsoft и KiCad)
    SymbolCache       = 'D:\Projects\WinDbg\SymbolsCache'

    # Пути к инструментам ('' = искать автоматически)
    ProcDumpPath      = 'D:\Utils\ProcDump.exe'
    CdbPath           = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'

    # Коды исключений, на которых пишем first-chance дамп:
    #   C0000005 access violation, C0000409 fastfail/abort,
    #   80000003 breakpoint (wx-assert)
    ExceptionFilters  = @('C0000005', 'C0000409', '80000003')

    # Сколько дампов пишет procdump, не отцепляясь
    MaxDumpsPerAttach = 5

    # Full: -ma, вся память (гигабайты; для локального разбора)
    # Mini: -mp, стеки+регистры (десятки МБ; влезает во вложение GitLab)
    DumpType          = 'Full'

    # Невскрытые дампы прошлых сессий старше N часов при старте не трогаем
    OrphanMaxAgeHours = 24

    # Серверы символов (кэш добавляется автоматически)
    SymbolServers     = @(
        'srv*https://msdl.microsoft.com/download/symbols',
        'srv*https://symbols.kicad.org/kicad-stable'
    )
}