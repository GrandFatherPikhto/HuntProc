# hunt-proc.nightly.config.psd1 — the same hunter, but with KiCad
# nightly-channel symbols (https://symbols.kicad.org/kicad-nightly).
#
# Why a separate config: symbols.kicad.org serves DIFFERENT symbol sets per
# channel (kicad-stable is only export symbols, while testing/nightly have
# full private PDBs), so each channel gets its own isolated SymbolCache so
# that PDBs with the same module name but different content do not mix in a
# single cache.
#
# Usage (manual analysis of an existing dump with this channel):
#   powershell -File hunt-proc.ps1 -ConfigPath hunt-proc.nightly.config.psd1 -Analyze <path-to-dump>
#
# DumpDir/ProcessNames/ExceptionFilters etc. are the same as in the main
# config (not needed for -Analyze, but kept in case you want to run real
# hunting on nightly symbols with this config too).
@{
    ProcessNames      = @('kicad')
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # A dedicated nightly cache — keep it separate from other channels.
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
