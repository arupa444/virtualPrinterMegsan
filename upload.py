#!/usr/bin/env python3
"""
Virtual Cloud Printer - job uploader.

This script is launched by the mfilemon / clawmon print-port monitor for every
print job that is sent to one of our virtual printers.

The port monitor calls us (see setup.ps1, the registry "UserCommand" value) as:

    pythonw.exe upload.py  "<ps_file>"  "<job_id>"  "<printer_name>"  "<document_name>"

Flow for one job:
    1. mfilemon has already written the raw PostScript of the job to <ps_file>.
    2. We convert that PostScript to a PDF using Ghostscript.
    3. We look up which HTTPS URL belongs to <printer_name> in config.json.
    4. We POST the PDF (multipart/form-data) to that URL together with the
       document name.
    5. On success we delete the temp files; on failure we keep the PDF under
       .\failed\ so nothing is ever lost.

Everything is wrapped so the script NEVER raises out to the spooler and always
leaves a trace in log.txt next to this file. It uses only the Python standard
library, so the virtual-env created by `uv` needs no extra packages.
"""

import sys
import os
import io
import re
import json
import time
import uuid
import ssl
import subprocess
import traceback
import urllib.request
import urllib.error
from datetime import datetime

# --------------------------------------------------------------------------- #
# Paths (everything lives next to this file, in %ProgramData%\VirtualCloudPrinter)
# --------------------------------------------------------------------------- #
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
LOG_PATH = os.path.join(BASE_DIR, "log.txt")
FAILED_DIR = os.path.join(BASE_DIR, "failed")


def log(message):
    """Append a timestamped line to log.txt (best-effort, never throws)."""
    line = "%s  %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), message)
    try:
        with io.open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass
    # Also print for the case where a console python.exe is used for debugging.
    try:
        print(line)
    except Exception:
        pass


def load_config():
    # utf-8-sig transparently strips a UTF-8 BOM if one is present (Windows
    # PowerShell tools often add one) and still reads BOM-less files fine.
    with io.open(CONFIG_PATH, "r", encoding="utf-8-sig") as fh:
        return json.load(fh)


def sanitize_filename(name, default="document"):
    """Make a string safe to use as an upload filename and ensure a .pdf suffix."""
    if not name:
        name = default
    # Strip characters that are illegal in Windows filenames / HTTP headers.
    bad = '<>:"/\\|?*\r\n\t'
    cleaned = "".join(ch for ch in name if ch not in bad).strip()
    if not cleaned:
        cleaned = default
    # Trim absurd lengths.
    cleaned = cleaned[:180]
    if not cleaned.lower().endswith(".pdf"):
        cleaned += ".pdf"
    return cleaned


def _version_key(name):
    """Sort key that orders 'gs10.03.1' above 'gs9.55' (numeric, not lexicographic)."""
    nums = re.findall(r"\d+", name)
    return [int(x) for x in nums] if nums else [0]


def find_ghostscript(config):
    """Return a usable Ghostscript console executable path, or None."""
    # 1. Explicit path from config.
    gs = (config.get("ghostscript_path") or "").strip()
    if gs and os.path.isfile(gs):
        return gs
    # 2. Search the usual install locations (highest version first).
    for root in (
        os.environ.get("ProgramFiles", r"C:\Program Files"),
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
    ):
        gs_root = os.path.join(root, "gs")
        if os.path.isdir(gs_root):
            for ver in sorted(os.listdir(gs_root), key=_version_key, reverse=True):
                for exe in ("gswin64c.exe", "gswin32c.exe"):
                    p = os.path.join(gs_root, ver, "bin", exe)
                    if os.path.isfile(p):
                        return p
    # 3. Rely on PATH (no console window, bounded).
    creationflags = 0x08000000 if os.name == "nt" else 0
    for exe in ("gswin64c.exe", "gswin32c.exe", "gs"):
        try:
            subprocess.run(
                [exe, "--version"],
                capture_output=True,
                check=True,
                timeout=15,
                creationflags=creationflags,
            )
            return exe
        except Exception:
            continue
    return None


def convert_ps_to_pdf(gs_exe, ps_file, pdf_file):
    """Convert a PostScript file to PDF using Ghostscript. Raises on failure."""
    cmd = [
        gs_exe,
        "-dBATCH",
        "-dNOPAUSE",
        "-dSAFER",
        "-dQUIET",
        "-sDEVICE=pdfwrite",
        "-sOutputFile=" + pdf_file,
        ps_file,
    ]
    # CREATE_NO_WINDOW so nothing flashes when run from the spooler.
    creationflags = 0x08000000 if os.name == "nt" else 0
    result = subprocess.run(
        cmd, capture_output=True, creationflags=creationflags
    )
    if result.returncode != 0 or not os.path.isfile(pdf_file):
        raise RuntimeError(
            "Ghostscript failed (rc=%s): %s"
            % (result.returncode, result.stderr.decode("utf-8", "replace")[:500])
        )


def build_multipart(fields, file_field, file_name, file_bytes, content_type):
    """Build a multipart/form-data body. Returns (body_bytes, content_type_header)."""
    boundary = "----VirtualCloudPrinter" + uuid.uuid4().hex
    crlf = b"\r\n"
    buf = io.BytesIO()

    for key, value in fields.items():
        buf.write(b"--" + boundary.encode() + crlf)
        buf.write(
            ('Content-Disposition: form-data; name="%s"' % key).encode("utf-8") + crlf
        )
        buf.write(crlf)
        buf.write(str(value).encode("utf-8") + crlf)

    buf.write(b"--" + boundary.encode() + crlf)
    buf.write(
        (
            'Content-Disposition: form-data; name="%s"; filename="%s"'
            % (file_field, file_name)
        ).encode("utf-8")
        + crlf
    )
    buf.write(("Content-Type: %s" % content_type).encode("utf-8") + crlf)
    buf.write(crlf)
    buf.write(file_bytes)
    buf.write(crlf)
    buf.write(b"--" + boundary.encode() + b"--" + crlf)

    return buf.getvalue(), "multipart/form-data; boundary=%s" % boundary


def post_pdf(config, printer_cfg, doc_name, pdf_bytes, upload_name):
    """POST the PDF to the printer's URL. Raises on non-2xx / network error."""
    url = printer_cfg.get("url", "").strip()
    if not url:
        raise RuntimeError("No URL configured for this printer.")

    docname_field = printer_cfg.get("docname_field", config.get("docname_field", "docname"))
    file_field = printer_cfg.get("file_field", config.get("file_field", "file"))

    fields = {}
    fields.update(config.get("extra_fields", {}) or {})
    fields.update(printer_cfg.get("extra_fields", {}) or {})
    fields[docname_field] = doc_name

    body, content_type = build_multipart(
        fields, file_field, upload_name, pdf_bytes, "application/pdf"
    )

    headers = {}
    headers.update(config.get("headers", {}) or {})
    headers.update(printer_cfg.get("headers", {}) or {})
    headers["Content-Type"] = content_type

    request = urllib.request.Request(url, data=body, headers=headers, method="POST")

    timeout = float(config.get("timeout_seconds", 60))
    verify_tls = bool(printer_cfg.get("verify_tls", config.get("verify_tls", True)))
    ctx = None
    if url.lower().startswith("https"):
        ctx = ssl.create_default_context()
        if not verify_tls:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE

    with urllib.request.urlopen(request, timeout=timeout, context=ctx) as resp:
        status = getattr(resp, "status", resp.getcode())
        preview = resp.read(500).decode("utf-8", "replace")
        if not (200 <= status < 300):
            raise RuntimeError("Server returned HTTP %s: %s" % (status, preview))
        return status, preview


def keep_failed(pdf_file, upload_name):
    """Copy the PDF into .\failed\ so a failed upload is never lost."""
    try:
        if not os.path.isdir(FAILED_DIR):
            os.makedirs(FAILED_DIR)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        # Include a short random token so two failures in the same second with
        # the same document name cannot overwrite each other.
        dest = os.path.join(FAILED_DIR, "%s_%s_%s" % (stamp, uuid.uuid4().hex[:8], upload_name))
        if os.path.isfile(pdf_file):
            with open(pdf_file, "rb") as src, open(dest, "wb") as dst:
                dst.write(src.read())
            log("Saved un-uploaded PDF to %s" % dest)
    except Exception as exc:
        log("Could not save failed PDF: %s" % exc)


def main():
    # ---- parse the arguments handed to us by the port monitor ----
    args = sys.argv[1:]
    ps_file = args[0] if len(args) > 0 else ""
    job_id = args[1] if len(args) > 1 else ""
    printer_name = args[2] if len(args) > 2 else ""
    # The document name is the tail so titles with spaces survive even if the
    # monitor did not quote them.
    doc_name = " ".join(args[3:]).strip() if len(args) > 3 else ""
    if not doc_name:
        doc_name = os.path.splitext(os.path.basename(ps_file or "document"))[0]

    log("---- job start ---- printer=%r doc=%r jobid=%r ps=%r"
        % (printer_name, doc_name, job_id, ps_file))

    pdf_file = None
    try:
        config = load_config()

        if not ps_file or not os.path.isfile(ps_file):
            raise RuntimeError("PostScript spool file not found: %r" % ps_file)

        # Which printer / URL? Match exactly first, then case/space-insensitively,
        # so a small mismatch between the Windows printer name and the config key
        # does not silently mis-route the job.
        printers = config.get("printers", {}) or {}
        printer_cfg = printers.get(printer_name)
        if printer_cfg is None:
            norm = {str(k).strip().casefold(): v for k, v in printers.items()}
            printer_cfg = norm.get((printer_name or "").strip().casefold())
            if printer_cfg is not None:
                log("Printer %r matched a config entry after normalization." % printer_name)
        if printer_cfg is None:
            # Fall back to a default URL if the printer is not explicitly listed.
            default_url = config.get("default_url", "").strip()
            if default_url:
                printer_cfg = {"url": default_url}
                log("WARNING: printer %r not found in config; falling back to default_url %r."
                    % (printer_name, default_url))
            else:
                raise RuntimeError(
                    "Printer %r is not configured and no default_url is set." % printer_name
                )

        # Convert PS -> PDF.
        gs_exe = find_ghostscript(config)
        if not gs_exe:
            raise RuntimeError("Ghostscript not found. Set 'ghostscript_path' in config.json.")
        pdf_file = os.path.splitext(ps_file)[0] + ".pdf"
        convert_ps_to_pdf(gs_exe, ps_file, pdf_file)
        log("Converted to PDF: %s (%d bytes)" % (pdf_file, os.path.getsize(pdf_file)))

        with open(pdf_file, "rb") as fh:
            pdf_bytes = fh.read()

        upload_name = sanitize_filename(doc_name)

        # Upload, with retries. Clamp so retry_count <= 0 still means one attempt.
        retries = max(0, int(config.get("retry_count", 2)))
        delay = float(config.get("retry_delay_seconds", 3))
        success = False
        for attempt in range(1, retries + 2):
            try:
                status, preview = post_pdf(
                    config, printer_cfg, doc_name, pdf_bytes, upload_name
                )
                log("Upload OK (HTTP %s) on attempt %d -> %s"
                    % (status, attempt, printer_cfg.get("url")))
                success = True
                break
            except Exception as exc:
                log("Upload attempt %d failed: %s" % (attempt, exc))
                if attempt <= retries:
                    time.sleep(delay)

        if not success:
            # Preserve the PDF so the job is never lost, then clean the spool copies.
            keep_failed(pdf_file, upload_name)

        # Remove the temporary spool files (the PDF is preserved in .\failed\ on
        # failure; only delete the .ps once we have a PDF so a conversion failure
        # leaves the PostScript behind for debugging).
        for path in (ps_file, pdf_file):
            try:
                if path and os.path.isfile(path):
                    os.remove(path)
            except Exception:
                pass
        log("---- job %s ----" % ("done" if success else "FAILED (preserved in failed/)"))

    except Exception as exc:
        # Never propagate to the spooler. On a hard error (e.g. Ghostscript
        # failed) the .ps is intentionally left in spool\ for debugging.
        log("ERROR: %s" % exc)
        log(traceback.format_exc())


if __name__ == "__main__":
    main()
