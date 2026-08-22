# hunt-proc.stable.config.psd1 — the same hunter, but with KiCad
# stable-channel symbols (https://symbols.kicad.org/kicad-stable) in an
# ISOLATED cache.
#
# Why a separate config: this duplicates the channel of the main
# hunt-proc.config.psd1, but that one keeps SymbolCache =
# 'D:\Projects\WinDbg\SymbolsCache' (shared with Microsoft symbols, for real
# hunting). This config is for the same manual one-off symbol download as
# nightly/testing, with an isolated cache, for consistency across the three
# channels.
#
# Usage (manual analysis of an existing dump with this channel):
#   powershell -File hunt-proc.ps1 -ConfigPath hunt-proc.stable.config.psd1 -Analyze <path-to-dump>
#
# DumpDir/ProcessNames/ExceptionFilters etc. are the same as in the main config.
@{
    ProcessNames      = @('kicad')
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # A dedicated stable cache — keep it separate from the shared live cache.
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
