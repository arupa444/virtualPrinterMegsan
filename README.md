# Virtual Cloud Printer (Windows)

Create one or more **virtual printers** on Windows. Anything you print to them —
from any app (Word, Chrome, PDF viewers, your ERP, …) — is converted to a **PDF**
and **POSTed to an HTTPS URL** of your choice, together with the document name.

```
Any app  ─Print▶  "Your Printer"  ─▶  PDF  ─▶  HTTPS POST (docname + file)  ─▶  your URL
```

You can create **as many printers as you like**, each pointing at its **own URL**:

```
"Invoices"    →  https://api.example.com/invoices
"Contracts"   →  https://api.example.com/contracts
"Backup"      →  https://other.example.com/upload
```

---

## Quick start

1. **Double-click `install.bat`** and approve the Administrator prompt (UAC).
2. When asked, type a **printer name** (e.g. `Invoices`) and the **HTTPS URL** it
   should send to.
3. Wait while it sets everything up (first run downloads a few tools — see below).
4. Done. Open any app → Print → pick your printer. The job is uploaded as a PDF.

To add another printer later: **double-click `add-printer.bat`**.
To check things are working: **double-click `status.bat`**.
To remove everything: **double-click `uninstall.bat`**.

---

## Full setup on a desktop, from `git clone` to a working printer

On the target **Windows** machine:

1. **Install Git** (if needed) — <https://git-scm.com/download/win> — then clone:
   ```bat
   git clone https://github.com/arupa444/virtualPrinterMegsan.git
   cd virtualPrinterMegsan
   ```
   (Or download the repo ZIP from GitHub and extract it.)

2. *(Optional but recommended for a first run)* **Start the local simulator** so
   you can watch jobs arrive, in a separate terminal:
   ```bat
   cd simulator
   run.bat
   ```
   It prints an **admin token** and serves `http://localhost:8000/`. Open that
   page, paste the token, create a link, and copy its ingest URL
   (`http://localhost:8000/ingest/<token>`). See [simulator/README.md](simulator/README.md).

3. **Install the printer.** Back in the repo root, **double-click `install.bat`**
   (approve the UAC prompt). When prompted, enter:
   - a **printer name** (e.g. `Invoices`)
   - the **URL** — paste the simulator link from step 2, or your real HTTPS endpoint.

4. **Print.** Open any app → Print → choose your printer. The job is converted to
   PDF and POSTed. If you used the simulator, refresh its dashboard to see the PDF
   and document name; otherwise check your endpoint. `status.bat` and
   `%ProgramData%\VirtualCloudPrinter\log.txt` confirm what happened.

5. **Add more printers** anytime with `add-printer.bat`; **remove everything**
   with `uninstall.bat`.

> For confidential/production data, read
> [COMPLIANCE-AND-PRIVACY.md](COMPLIANCE-AND-PRIVACY.md) first — especially the
> Ghostscript licensing note and the HTTPS/`verify_tls` requirement.

## What gets installed (automatically, on first run)

The installer is self-contained; it fetches what it needs the first time:

| Component | Why | How it's obtained |
|---|---|---|
| **uv** + a private **Python 3.12** | runs the uploader | `winget` or the official uv installer; Python is placed under `%ProgramData%\VirtualCloudPrinter\python` |
| **Ghostscript** | converts PostScript → PDF | `winget` (`ArtifexSoftware.GhostScript`), or the official installer from GitHub |
| **mfilemon** print-port monitor | captures the print job and runs our uploader | silent download + install of `mfilemon-setup.exe` |
| **Microsoft PS Class Driver** | inbox PostScript driver | already in Windows |

Everything the tool itself creates lives in **`%ProgramData%\VirtualCloudPrinter\`**:
`upload.py`, `config.json`, the `venv`, `python`, `spool\`, `failed\`, and `log.txt`.

> **Requirements:** Windows 10/11 (64-bit), Administrator rights for install, and
> internet access on first run to fetch the tools above.

---

## Test it locally first (recommended)

Before pointing at a real server, verify the whole pipeline on your own machine:

```bat
python test_server.py
```

It prints a URL like `http://localhost:8000/upload`. Set a printer to that URL
(either during install, or edit `config.json` — see below), then print anything.
The received PDF and the document name show up in the console and in `.\received\`.

---

## Configuration — `config.json`

Located at `%ProgramData%\VirtualCloudPrinter\config.json`. The installer manages
it for you, but you can edit it directly (no reinstall needed — changes apply to
the next print job).

```jsonc
{
  "printers": {
    "Invoices": {                       // MUST match the Windows printer name
      "url": "https://api.example.com/invoices",
      "docname_field": "docname",       // form field name for the document name
      "file_field": "file",             // form field name for the PDF
      "extra_fields": { "source": "erp" },  // any extra form fields to send
      "headers": { "Authorization": "Bearer XYZ" },  // any extra HTTP headers
      "verify_tls": true                // set false only for self-signed test certs
    }
  },

  "default_url": "",                    // used if a printer isn't listed above
  "timeout_seconds": 60,
  "retry_count": 2,                     // retries on upload failure
  "retry_delay_seconds": 3,
  "ghostscript_path": "C:\\Program Files\\gs\\gs10.03.1\\bin\\gswin64c.exe"
}
```

### What the server receives
An HTTP **POST** with `Content-Type: multipart/form-data` containing:
- **`docname`** — the document name Windows assigned to the job (e.g. `Invoice 42`).
- **`file`** — the PDF, sent with filename `<docname>.pdf` and type `application/pdf`.

(The field names are configurable per printer via `docname_field` / `file_field`.)

---

## How it works (under the hood)

1. The printer uses the inbox **Microsoft PS Class Driver**, so every job becomes
   **PostScript**.
2. A redirection **port** (registered under the **mfilemon / clawmon** port monitor)
   receives that PostScript, writes it to `spool\`, and launches **`upload.py`**,
   passing the spool file, job id, **printer name** (`%r`) and **document name** (`%t`).
3. `upload.py` runs **Ghostscript** to turn the PostScript into a PDF, looks up the
   printer's URL in `config.json`, and **POSTs** the PDF.
4. On success the temp files are deleted; on failure the PDF is kept in `failed\`
   and the error is written to `log.txt` so nothing is ever lost.

---

## Using clawmon instead of mfilemon (optional)

You chose *clawmon* — but clawSoft publishes **no prebuilt clawmon binaries**, so a
one-click installer would have to compile C++ from source. Its parent **mfilemon**
is byte-for-byte compatible (same registry format, same `%t`/`%r`/`%f` macros) and
ships a ready installer, so the installer uses mfilemon by default.

If you specifically want clawmon, build it (Visual Studio) or obtain
`clawmon.dll`, `clawmonui.dll`, and `regmon.exe`, drop them into the **`vendor\`**
folder next to `install.bat`, and re-run `install.bat`. The installer detects them
and registers clawmon automatically. Source: <https://github.com/hessandrew/clawmon>.

---

## Troubleshooting

- **Nothing arrives at my URL.** Open `status.bat` and read the tail of the log, or
  open `%ProgramData%\VirtualCloudPrinter\log.txt`. Each job writes a block there.
- **`Ghostscript not found`.** Set the full path to `gswin64c.exe` in
  `config.json` → `ghostscript_path`.
- **Failed uploads.** Check `%ProgramData%\VirtualCloudPrinter\failed\` — every PDF
  that couldn't be uploaded is preserved there.
- **Want to see errors live?** Temporarily change the port's `UserCommand` from
  `pythonw.exe` to `python.exe`, or just run a job and watch `log.txt`.
- **SmartScreen warning** when the mfilemon installer runs: it's an older signed
  community tool; approve it once, or pre-install mfilemon yourself.

---

## Security notes

- The install folder `%ProgramData%\VirtualCloudPrinter` is locked down to
  **SYSTEM + Administrators** during install (ordinary users print through the
  spooler and never need access). This both protects any auth tokens you put in a
  printer's `headers` and prevents a local privilege-escalation vector (the
  uploader runs as SYSTEM).
- Because of that lock-down, edit `config.json` from an **elevated** editor
  (Run as administrator), or via `add-printer.bat`.
- Ghostscript runs with `-dSAFER`. Jobs are only ever sent to the URL configured
  for the printer that received them (matched case/space-insensitively); if a
  printer isn't in `config.json` and no `default_url` is set, the job is preserved
  in `failed\` rather than sent anywhere.

## Files in this project

| File | Purpose |
|---|---|
| `install.bat` | one-click install + create first printer (elevates) |
| `add-printer.bat` | create an additional printer → its own URL |
| `status.bat` | show monitor, printers, URLs, recent log |
| `uninstall.bat` | remove printers, port, and files |
| `setup.ps1` | all the actual logic (called by the .bat files) |
| `upload.py` | the per-job converter + uploader (stdlib only) |
| `config.template.json` | starting configuration |
| `test_server.py` | local receiver for end-to-end testing |
| `vendor/` | drop clawmon binaries here to use clawmon instead of mfilemon |
| `simulator/` | FastAPI receiver simulator (create links, receive & view PDFs) |
| `COMPLIANCE-AND-PRIVACY.md` | licensing, regulatory & privacy guidance (read for pharma use) |
| `NOTICE` / `LICENSE` | third-party license obligations / this project's MIT license |
