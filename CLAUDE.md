# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Windows **virtual printer** toolkit. It installs one or more printers that appear in the normal print dialog; anything printed to them is converted to a PDF and POSTed (multipart/form-data) to a per-printer HTTPS URL. Target OS is **Windows 10/11 x64**, but the Python HTTP layer is developed and tested on any platform (this repo's dev machine is macOS).

## The pipeline (read this before touching anything)

A single print job flows through four layers that live in different files/tools. Understanding the whole chain requires this map:

```
App ─Print▶ "Printer" ─(Microsoft PS Class Driver → PostScript)▶ redirection port
   ▶ mfilemon/clawmon port monitor ─(writes .ps to spool\, launches UserCommand)▶ upload.py
   ▶ upload.py: Ghostscript PS→PDF, look up URL by printer name, HTTPS POST ▶ your URL
```

- **Port monitor = mfilemon** (`"Multi File Port Monitor"`, `mfilemon.dll`) *or* **clawmon** (`"clawmon printer port monitor"`, `clawmon.dll`) — same C++ code/interface. clawmon has no prebuilt binaries, so `setup.ps1` auto-installs mfilemon by default and uses clawmon only if its DLLs are dropped in `vendor/`.
- The monitor stores each port as a **direct registry subkey** of `HKLM\SYSTEM\CurrentControlSet\Control\Print\Monitors\<MonitorName>\<PortName>`. `setup.ps1` (`Set-Port`) writes the values via the .NET `Microsoft.Win32.Registry` API (needed because the port name ends in a colon). Value names/types are fixed by the monitor's source: `OutputPath`/`FilePattern`/`UserCommand`/`ExecPath`/`User`/`Domain`/`Password` are `REG_SZ`; `Overwrite`/`WaitTermination`/`WaitTimeout`/`PipeData`/`HideProcess` are `REG_DWORD`.
- Ports are loaded from the registry at **spooler start**, so `Set-Port` uses **stop-Spooler → write registry → start-Spooler** ordering (writing while the spooler runs risks the monitor clobbering the key on shutdown).
- The monitor's macros (from its `pattern.cpp`): **`%f`** = spooled file path, **`%j`** = job id, **`%r`** = **printer name**, **`%t`** = **document/job title**. `PipeData=0` means the job is written to `%f` and *then* `UserCommand` is launched (file already complete); the monitor uses `CreateProcess` (no shell), so no cmd metachar interpretation.

## Critical coupling: the UserCommand ↔ upload.py argv contract

`setup.ps1` writes this exact `UserCommand`:
```
"<venv>\Scripts\pythonw.exe" -P "<base>\upload.py" "%f" "%j" "%r" "%u" "%t"
```
`upload.py:main()` maps it as `ps_file=argv[1]`, `job_id=argv[2]`, `printer=argv[3]`, `user=argv[4]`, `docname=" ".join(argv[5:])` (tail-join so document titles with spaces survive; `%u`=user is a single token placed *before* the docname tail). `-P` is a Python **interpreter** flag (keeps the script dir off `sys.path[0]` — a hardening measure, see below), so it does **not** shift the argv mapping. **If you change the argument order or count in either place, change both.**

## Optional per-job identifier: the set-id helper

`set-id.bat` → `set-id.ps1` (run by the **normal user**, no elevation) writes `%ProgramData%\VirtualCloudPrinter\ids\<user>.id` (JSON `{id, once}`). `upload.py:read_pending_id()` reads it keyed by `%u`, attaches it as the `registration_field` (default `registration_number`) form field, and consumes the file if `once`. The `ids\` subfolder is the **only** user-writable path under `$Base` (granted Authenticated Users `M` in `Do-Install`); it is safe because `upload.py` only reads it as opaque text and never imports from it. The username sanitizer must stay identical on both sides (`upload.py:sanitize_userfile` ↔ the `-replace` in `set-id.ps1`).

## Routing: config.json

Everything runs from `%ProgramData%\VirtualCloudPrinter\` (chosen so the SYSTEM-context spooler can read it). `config.json` maps **printer name → URL**; `upload.py` looks up `config["printers"][<%r>]` and falls back to `default_url`. One shared port serves every printer — adding a printer only adds a driver+printer+config entry, never a new port. `config.template.json` is the seed; `setup.ps1` (`Update-Config`) copies it on first install and edits it thereafter via `ConvertFrom-Json`/`ConvertTo-Json`.

## Security / correctness invariants (do not regress)

- **`$Base` ACL is hardened.** `Do-Install` runs `icacls $Base /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"` because `upload.py` runs as **SYSTEM** from `$Base`; the default `C:\ProgramData` ACL lets any user create files in child folders, which would let a standard user plant a sibling module (`ssl.py`, `json.py`, …) imported ahead of the stdlib → SYSTEM code execution. The `-P` flag on the launch line is the defense-in-depth partner. Keep both.
- **config.json must be written BOM-less.** Windows PowerShell 5.1 `Set-Content -Encoding UTF8` prepends a BOM that breaks Python's `json.load`; `Update-Config` uses `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))` and `upload.py` reads with `utf-8-sig`. Don't revert either.

## Hard constraints

- **`upload.py` and `test_server.py` are standard-library only** (no `requests`, no pip). The `uv`-managed venv exists to provide a private Python interpreter, not packages. Keep it that way — the uploader must run under the SYSTEM account with zero install-time package fetches.
- Per the user's global rule, provision Python/venv with **`uv`** (`uv venv`), never pip.
- `upload.py` must **never raise out to the spooler** and must preserve failed jobs — on upload failure the PDF is kept under `%ProgramData%\VirtualCloudPrinter\failed\` and errors go to `log.txt`.

## Commands

```bash
# Syntax-check the Python (works anywhere)
python3 -m py_compile upload.py test_server.py

# Local end-to-end test of the HTTP contract (no Windows needed):
python3 test_server.py 8000        # terminal 1 — prints received docname + saves PDF to ./received/
#   then point a printer/config URL at http://localhost:8000/upload and print,
#   or drive upload.py's post_pdf()/build_multipart() directly against it.
```

```powershell
# Windows install/manage (the .bat wrappers just elevate and call these):
powershell -ExecutionPolicy Bypass -File setup.ps1 -Action install                     # deps + first printer
powershell -ExecutionPolicy Bypass -File setup.ps1 -Action add -PrinterName N -Url U    # add a printer
powershell -ExecutionPolicy Bypass -File setup.ps1 -Action status                       # monitor/printers/log tail
powershell -ExecutionPolicy Bypass -File setup.ps1 -Action uninstall                    # remove printers/port/files
```

`setup.ps1` requires Administrator (the `.bat` files self-elevate via UAC) and internet on first run (fetches `uv`, Ghostscript, mfilemon). `-Action status` and reading `%ProgramData%\VirtualCloudPrinter\log.txt` are the primary debugging tools; switch the port's `UserCommand` from `pythonw.exe` to `python.exe` to see a job run in a console.

## Debugging print jobs

Every job writes a block to `log.txt`. If nothing reaches the URL: confirm the printer name exactly matches a `config.json` key (`%r` is case/space-sensitive), confirm `ghostscript_path` resolves, and check `failed/` for preserved PDFs.
