# hunt-proc.config.psd1 — settings for the hunt-proc.ps1 hunter (lives next to the script).
# Precedence: command-line parameters > this file > script defaults.
# .psd1 format is native to PowerShell, no dependencies.
@{
    # Which processes to watch (names WITHOUT .exe). Several allowed:
    # ProcessNames = @('kicad', 'freecad', 'librepcb')
    ProcessNames      = @('kicad')

    # Where to store dumps, hunter.log and procdump_*.txt
    DumpDir           = 'D:\Projects\WinDbg\KiCad'

    # Local symbol cache (shared by Microsoft and KiCad)
    SymbolCache       = 'D:\Projects\WinDbg\SymbolsCache'

    # Paths to the tools ('' = auto-discover)
    ProcDumpPath      = 'D:\Utils\ProcDump.exe'
    CdbPath           = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'

    # Exception codes on which to write a first-chance dump:
    #   C0000005 access violation, C0000409 fastfail/abort,
    #   80000003 breakpoint (wx-assert)
    ExceptionFilters  = @('C0000005', 'C0000409', '80000003')

    # How many dumps procdump writes without detaching
    MaxDumpsPerAttach = 5

    # Full: -ma, whole memory (gigabytes; for local analysis)
    # Mini: -mp, stacks+registers (tens of MB; fits into a GitLab attachment)
    DumpType          = 'Full'

    # Unopened dumps from previous sessions older than N hours are not touched at startup
    OrphanMaxAgeHours = 24

    # Symbol servers (the cache is added automatically)
    SymbolServers     = @(
        'srv*https://msdl.microsoft.com/download/symbols',
        'srv*https://symbols.kicad.org/kicad-stable'
    )
}
