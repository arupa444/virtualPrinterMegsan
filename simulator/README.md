# Receiver Simulator (FastAPI)

A local stand-in for the server your virtual printers POST to. Use it to test the
whole pipeline end-to-end before you have a real backend.

**Model:** you create a **link** — an ingest URL whose secret token *is* the API
key (`http://<host>:8000/ingest/<token>`). You paste that URL into a printer in
the Virtual Cloud Printer app; every job printed to that printer is POSTed here,
stored, and shown in the dashboard grouped by link.

## Run it

```bash
# macOS / Linux
cd simulator
./run.sh
```
```bat
REM Windows
cd simulator
run.bat
```

Both scripts use **uv** to create a `.venv`, install `fastapi` / `uvicorn` /
`python-multipart`, and start the server on `http://localhost:8000`.

On first start an **admin token** is generated and printed to the console (and
saved to `data/admin_token.txt`). To pin your own: set `SIM_ADMIN_TOKEN` before
running.

## Use it

1. Open `http://localhost:8000/`, paste the **admin token**, click **Save**.
2. Type a label (e.g. `Invoices`) → **Create link**. Copy the ingest URL.
3. In the printer app, set that URL as a printer's `url`
   (during `install.bat` / `add-printer.bat`, or edit `config.json`).
4. Print something → it appears under that link in the dashboard; click the file
   count to view and download the received PDFs.

## API (all admin calls send header `X-Admin-Token: <token>`)

| Method & path | Purpose |
|---|---|
| `POST /api/links` `{ "label": "..." }` | create a link → `{ token, ingest_url }` |
| `GET /api/links` | list links + file counts |
| `GET /api/links/{token}/files` | files received on a link |
| `GET /api/files/{id}` | download a stored file |
| `POST /ingest/{token}` | **the printer posts here** (multipart `docname` + `file`) |
| `GET /healthz` | liveness |

## Storage

Everything is local: metadata in `data/sim.db` (SQLite), files under
`data/files/<token>/`. Nothing is sent anywhere. Delete `data/` to reset.

## ⚠️ This is a simulator, not production

- It serves plain **HTTP**. For real confidential documents, run it behind a
  TLS-terminating reverse proxy (nginx/Caddy) or add HTTPS, and keep the printer
  side on `https://` with `verify_tls: true`.
- The link token is a bearer credential in a URL — treat generated links as
  secrets. Rotate by creating a new link and deleting the old one's data.
- No retention limits, virus scanning, or audit trail beyond basic metadata —
  add those before using it for anything real.
