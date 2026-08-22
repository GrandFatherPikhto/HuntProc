# hunt-proc.testing.config.psd1 — the same hunter, but with KiCad
# testing-channel symbols (https://symbols.kicad.org/kicad-testing).
#
# Why a separate config: symbols.kicad.org serves DIFFERENT symbol sets per
# channel — kicad-stable turned out to be only export symbols for
# kicad.exe 10.0.6.50856, while testing hosts real private PDBs.
# Each channel has its own isolated SymbolCache so that PDBs with the same
# module name but different content do not mix in a single cache.
#
# Usage (manual analysis of an existing dump with this channel):
#   powershell -File hunt-proc.ps1 -ConfigPath hunt-proc.testing.config.psd1 -Analyze <path-to-dump>
#
# DumpDir/ProcessNames/ExceptionFilters etc. are the same as in the main
# config (not needed for -Analyze, but kept in case you want to run real
# hunting on testing symbols with this config too).
@{
    ProcessNames      = @('kicad')
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # A dedicated testing cache — keep it separate from other channels.
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
