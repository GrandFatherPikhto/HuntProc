# hunt-proc.stable.config.psd1 — тот же охотник, но с символами KiCad
# stable-канала (https://symbols.kicad.org/kicad-stable) в ИЗОЛИРОВАННОМ кэше.
#
# Зачем отдельный конфиг: это дублирует канал основного hunt-proc.config.psd1,
# но тот держит SymbolCache = 'D:\Projects\WinDbg\SymbolsCache' (общий с
# Microsoft-символами, для боевой охоты). Этот конфиг — для того же ручного
# VPN-workflow, что и nightly/testing, с изолированным кэшем, для
# единообразия трёх каналов.
#
# Использование (ручной разбор уже существующего дампа этим каналом):
#   powershell -File hunt-proc.ps1 -ConfigPath hunt-proc.stable.config.psd1 -Analyze <путь-к-дампу>
#
# DumpDir/ProcessNames/ExceptionFilters и т.д. те же, что в основном конфиге.
@{
    ProcessNames      = @('kicad')
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # Отдельный кэш под stable — не мешаем с боевым общим кэшем.
    SymbolCache       = 'D:\Projects\WinDbg\KiCad\stable'

    ProcDumpPath      = 'D:\Utils\ProcDump.exe'
    CdbPath           = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'

    ExceptionFilters  = @('C0000005', 'C0000409', '80000003')
    MaxDumpsPerAttach = 5
    DumpType          = 'Full'
    OrphanMaxAgeHours = 24

    SymbolServers     = @(
        'srv*https://msdl.microsoft.com/download/symbols',
        'srv*https://symbols.kicad.org/kicad-stable'
    )
}
