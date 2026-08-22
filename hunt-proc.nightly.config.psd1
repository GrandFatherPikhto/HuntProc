# hunt-proc.nightly.config.psd1 — тот же охотник, но с символами KiCad
# nightly-канала (https://symbols.kicad.org/kicad-nightly).
#
# Зачем отдельный конфиг: symbols.kicad.org отдаёт РАЗНЫЕ наборы символов
# по разным каналам (kicad-stable бывает только export-символами, а
# testing/nightly — полноценные приватные PDB), поэтому у каждого канала
# свой изолированный SymbolCache, чтобы PDB с одинаковым именем модуля,
# но разным содержимым не смешивались в одном кэше.
#
# Использование (ручной разбор уже существующего дампа этим каналом):
#   powershell -File hunt-proc.ps1 -ConfigPath hunt-proc.nightly.config.psd1 -Analyze <путь-к-дампу>
#
# DumpDir/ProcessNames/ExceptionFilters и т.д. те же, что в основном конфиге
# (не нужны для -Analyze, но держим на случай если этим же конфигом захочется
# погонять и боевую охоту на nightly-символах).
@{
    ProcessNames      = @('kicad')
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # Отдельный кэш под nightly — не мешаем с другими каналами.
    SymbolCache       = 'D:\Projects\WinDbg\KiCad\nightly'

    ProcDumpPath      = 'D:\Utils\ProcDump.exe'
    CdbPath           = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'

    ExceptionFilters  = @('C0000005', 'C0000409', '80000003')
    MaxDumpsPerAttach = 5
    DumpType          = 'Full'
    OrphanMaxAgeHours = 24

    SymbolServers     = @(
        'srv*https://msdl.microsoft.com/download/symbols',
        'srv*https://symbols.kicad.org/kicad-nightly'
    )
}
