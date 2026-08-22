# hunt-proc.testing.config.psd1 — тот же охотник, но с символами KiCad
# testing-канала (https://symbols.kicad.org/kicad-testing).
#
# Зачем отдельный конфиг: symbols.kicad.org отдаёт РАЗНЫЕ наборы символов
# по разным каналам — kicad-stable оказался только export-символами для
# kicad.exe 10.0.6.50856, а на testing лежат настоящие приватные PDB.
# У каждого канала свой изолированный SymbolCache, чтобы PDB с одинаковым
# именем модуля, но разным содержимым не смешивались в одном кэше.
#
# Использование (ручной разбор уже существующего дампа этим каналом):
#   powershell -File hunt-proc.ps1 -ConfigPath hunt-proc.testing.config.psd1 -Analyze <путь-к-дампу>
#
# DumpDir/ProcessNames/ExceptionFilters и т.д. те же, что в основном конфиге
# (не нужны для -Analyze, но держим на случай если этим же конфигом захочется
# погонять и боевую охоту на testing-символах).
@{
    ProcessNames      = @('kicad')
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # Отдельный кэш под testing — не мешаем с другими каналами.
    SymbolCache       = 'D:\Projects\WinDbg\KiCad\testing'

    ProcDumpPath      = 'D:\Utils\ProcDump.exe'
    CdbPath           = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'

    ExceptionFilters  = @('C0000005', 'C0000409', '80000003')
    MaxDumpsPerAttach = 5
    DumpType          = 'Full'
    OrphanMaxAgeHours = 24

    SymbolServers     = @(
        'srv*https://msdl.microsoft.com/download/symbols',
        'srv*https://symbols.kicad.org/kicad-testing'
    )
}
