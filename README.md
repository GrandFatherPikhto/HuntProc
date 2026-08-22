# Process Hunter (hunt-proc.ps1)

A universal script for automatically collecting memory dumps and analyzing crashes of arbitrary processes (not only KiCad). It runs as a daemon: watches for new instances of the configured executables, attaches `procdump` (Sysinternals) to each one, and on crash or exit automatically analyzes the dump with `cdb.exe` and prints a short verdict.

---

## Features

- **Multi-process** — watches several applications at once (list in the config).
- **Flexible exception filters** — catches first-chance exceptions (AV, fastfail, breakpoint, etc.) and process termination (`-t`).
- **Background auto-analysis** — each fresh dump is processed by `cdb.exe` in a separate background job (`Start-Job`) without blocking the main loop.
- **Full or mini dump** — your choice: `-ma` (full memory, gigabytes) or `-mp` (stacks/registers only, tens of MB — convenient for GitLab/email attachments).
- **Symbol support** — several symbol servers (Microsoft, KiCad, any others); shared cache.
- **Orphan pickup** — on startup it finds unanalyzed dumps from previous sessions and analyzes them too.
- **Manual analysis mode** — `-Analyze path\to\file.dmp` for a one-off analysis.
- **Autostart** — registers a Windows Scheduled Task to run at logon.

---

## Requirements

- **Windows 10 / 11 / Server 2016+**
- **PowerShell 5.1** (or newer)
- **ProcDump** — download from [Sysinternals](https://learn.microsoft.com/sysinternals/downloads/procdump) (`procdump.exe`)
- **cdb.exe** — part of the **Windows SDK** (Debugging Tools for Windows)  
  Typical paths:
  - `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe`
  - `C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe`
- **Access to symbol servers** (local cache or internet) — configured in the config file.

---

## Installation and setup

1. **Copy the files** to a convenient folder:
   - `hunt-proc.ps1` — the main script
   - `hunt-proc.config.psd1` — the settings file (lives next to the script)

2. **Edit the config** (`hunt-proc.config.psd1`) to fit your needs.  
   Example contents:

```powershell
@{
    ProcessNames      = @('kicad', 'freecad')   # without .exe
    DumpDir           = 'D:\Projects\WinDbg\KiCad'
    SymbolCache       = 'D:\Projects\WinDbg\SymbolsCache'
    ProcDumpPath      = 'D:\Utils\ProcDump.exe'
    CdbPath           = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
    ExceptionFilters  = @('C0000005', 'C0000409', '80000003')
    MaxDumpsPerAttach = 5
    DumpType          = 'Full'          # or 'Mini'
    OrphanMaxAgeHours = 24
    SymbolServers     = @(
        'srv*https://msdl.microsoft.com/download/symbols',
        'srv*https://symbols.kicad.org/kicad-stable'
    )
}
```

3. **Make sure the paths to `procdump.exe` and `cdb.exe` are correct** — the script tries to find them automatically, but it is better to set them explicitly.

4. **Create the directories** named in `DumpDir` and `SymbolCache` — they are created automatically if missing.

---

## Usage

### Manual run (debugging)

```powershell
powershell -ExecutionPolicy Bypass -File .\hunt-proc.ps1
```

The script starts watching processes from the `ProcessNames` list. The console shows messages about startup, attachment, new dumps, and verdicts.  
To stop, press `Ctrl+C`.

### Manual analysis of a single dump

```powershell
.\hunt-proc.ps1 -Analyze "D:\dumps\kicad_220101_123456.dmp"
```

The dump is analyzed with the current symbol settings; the result is saved to `*.analysis.txt`, and a short verdict is printed to the console.

### Install the autostart task

```powershell
.\hunt-proc.ps1 -Install
```

Creates the `ProcDumpHunter` scheduled task that runs the script at every logon of the current user.

### Remove the task

```powershell
.\hunt-proc.ps1 -Uninstall
```

### Restart the task (if it is already running)

```powershell
Stop-ScheduledTask -TaskName "ProcDumpHunter"
Start-ScheduledTask -TaskName "ProcDumpHunter"
```

Or via the `taskschd.msc` snap-in.

---

## Configuration (.psd1 file)

| Parameter | Type | Description |
|-----------|------|-------------|
| `ProcessNames` | `string[]` | Process names **without `.exe`** (e.g. `kicad`, `freecad`). |
| `DumpDir` | `string` | Directory for dumps, logs, and `procdump` output files. |
| `SymbolCache` | `string` | Local cache for PDB files (used by `cdb` and `symchk`). |
| `ProcDumpPath` | `string` | Full path to `procdump.exe`. If empty, the script searches `PATH` and typical folders. |
| `CdbPath` | `string` | Full path to `cdb.exe`. If empty, auto-search. |
| `ExceptionFilters` | `string[]` | HEX exception codes that `procdump` reacts to (first-chance). |
| `MaxDumpsPerAttach` | `int` | How many dumps may be created per process-monitoring session. |
| `DumpType` | `string` | `Full` (complete dump, `-ma`) or `Mini` (stacks and registers only, `-mp`). |
| `OrphanMaxAgeHours` | `int` | Dumps older than this many hours are considered "old" and are not analyzed at startup. |
| `SymbolServers` | `string[]` | List of symbol servers (`srv*<URL>` format). The `SymbolCache` cache is added automatically. |

**Priority:** command-line parameters (when set) override config values, which in turn override the hardcoded defaults inside the script.

---

## What happens while it runs

1. The **hunter** periodically scans system processes for names from `ProcessNames`.
2. For each new process it launches a separate `procdump` instance with the flags:
   - `-e 1` — first-chance exceptions
   - `-f` — exception code filters
   - `-t` — dump on termination (including a "silent" exit)
   - `-n N` — dump count limit
   - `-ma` or `-mp` — dump type
3. `procdump` writes dumps to `DumpDir` and keeps its log in `procdump_<process>_<PID>.txt`.
4. As soon as a new `.dmp` file appears, the script starts a background job (`Start-Job`) that runs `cdb` with:
   ```
   !analyze -v; .ecxr; kb; q
   ```
   The result is saved to `<dump_name>.analysis.txt`.
5. After analysis finishes, the script extracts from the text:
   - **FAILURE_BUCKET_ID** — a short error identifier
   - **trigger** — the first line with `***` (often contains the exception description)
   - **the first 8 unique stack frames** (function names)
   All of this is printed to `hunter.log` and to the console.

6. The loop continues; the hunter keeps watching for new processes and finished `procdump` instances.

---

## Symbols

The **symbol path** is assembled automatically from:
```
cache*$SymbolCache;$SymbolServers
```
where `$SymbolServers` is the array from the config.

If your network blocks `msdl.microsoft.com`, you can remove that entry from `SymbolServers` or keep only a local server (e.g. for KiCad).  
Make sure `SymbolCache` exists and is writable — `cdb` will store downloaded PDBs there.

---

## Channel configs and manual symbol prefetch

Besides the main `hunt-proc.config.psd1` (production hunting, `kicad-stable`,
cache shared with Microsoft symbols at `D:\Projects\WinDbg\SymbolsCache`) there
are three sibling configs for separate KiCad symbol channels:

| Config | Channel | Symbol cache |
|--------|---------|--------------|
| `hunt-proc.nightly.config.psd1` | `kicad-nightly` | `D:\Projects\WinDbg\KiCad\nightly` |
| `hunt-proc.testing.config.psd1` | `kicad-testing` | `D:\Projects\WinDbg\KiCad\testing` |
| `hunt-proc.stable.config.psd1` | `kicad-stable` | `D:\Projects\WinDbg\KiCad\stable` |

Each channel has its own isolated cache: `symbols.kicad.org` serves different
symbol sets per channel, and PDBs with the same module name but different
contents must not mix in one cache.

### Manual dump analysis with a specific channel

```powershell
.\hunt-proc.ps1 -ConfigPath hunt-proc.testing.config.psd1 -Analyze "D:\dumps\kicad.dmp"
```

### One-off PDB prefetch for the installed KiCad (no dump needed)

`fetch-kicad-symbols.ps1` downloads symbols for every binary of the installed
KiCad version via `symchk /r`, without depending on a specific dump. Workflow:
make sure the symbol servers are reachable → run the script → wait for it to
finish — afterwards `cdb`/`hunt-proc` read symbols from the local cache and no
network access is needed.

```powershell
.\fetch-kicad-symbols.ps1 -Channel testing
```

The script prints the installed KiCad version, warns about the upcoming
network requests, and waits for confirmation (Enter) before contacting the
servers. Parameters:

| Parameter | Description |
|-----------|-------------|
| `-Channel` | Symbol channel: `nightly`, `testing`, or `stable` (required). |
| `-KicadExe` | Path to `kicad.exe` (defaults to the standard install path). |
| `-SymChkPath` | Path to `symchk.exe` (by default searched next to `cdb.exe`). |

---

## Dump types and their size

- **Full** (`-ma`) — contains the whole process address space. Size can reach several gigabytes. Recommended for deep local analysis.
- **Mini** (`-mp`) — only thread stacks, registers, and key structures. Usually 20–100 MB, so dumps can be attached to bug reports or sent by email.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **ProcDump not found** | Download `procdump.exe` and set the path in the config (or put it in `C:\Tools`). |
| **cdb not found** | Install the Windows SDK (select "Debugging Tools for Windows") or set the path in the config. |
| **Analysis shows only addresses, no function names** | Check access to the symbol servers. Run `!sym noisy` manually for diagnostics. Make sure the PDBs match your binary versions. |
| **Long timeouts during analysis** | Remove unreachable servers (e.g. `msdl.microsoft.com`) from `SymbolServers`. |
| **Script does not see fresh dumps** | Check the dump creation time (must be later than `$hunterStart`). If the dump was created before the hunter started, it is treated as an orphan (if not older than `OrphanMaxAgeHours`). |
| **Several hunters at once** | A `hunter.lock` file is created in `DumpDir`. A second instance exits with an "already running" message. |

---

## Examples

**Run with a custom config (not next to the script):**
```powershell
.\hunt-proc.ps1 -ConfigPath "C:\my_settings\my_config.psd1"
```

**Override a parameter via the command line (overrides the config):**
```powershell
.\hunt-proc.ps1 -DumpType Mini -MaxDumpsPerAttach 2
```

**Auto-install with parameters (the config is still used for the rest):**
```powershell
.\hunt-proc.ps1 -Install -DumpDir "E:\dumps" -SymbolCache "E:\symcache"
```

---

## License and acknowledgements

The script is provided "as is", without any warranties.  
Uses:
- **ProcDump** — © Microsoft / Sysinternals
- **cdb / Debugging Tools for Windows** — © Microsoft

---

**Happy bug hunting! 🐾**
