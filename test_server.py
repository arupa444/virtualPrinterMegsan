#!/usr/bin/env python3
"""
Virtual Cloud Printer - local test receiver.

Run this on the same machine to verify the whole pipeline WITHOUT a real
server. It accepts the multipart/form-data POST that upload.py sends, saves
the PDF, and prints the document name it received.

Usage:
    python test_server.py            # listens on http://localhost:8000/
    python test_server.py 9000       # custom port

Then point a printer at it, e.g. in config.json:
    "url": "http://localhost:8000/upload"
and print something to that printer. The PDF appears in .\received\.

Standard library only - no venv or packages required.
"""

import sys
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime

RECEIVED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "received")


def parse_multipart(headers, body):
    """Minimal multipart/form-data parser. Returns (fields dict, files list)."""
    ctype = headers.get("Content-Type", "")
    if "boundary=" not in ctype:
        return {}, []
    boundary = ctype.split("boundary=", 1)[1].strip().strip('"')
    delim = ("--" + boundary).encode()
    fields = {}
    files = []
    for part in body.split(delim):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        if b"\r\n\r\n" not in part:
            continue
        raw_headers, content = part.split(b"\r\n\r\n", 1)
        header_text = raw_headers.decode("utf-8", "replace")
        disp = ""
        for line in header_text.split("\r\n"):
            if line.lower().startswith("content-disposition"):
                disp = line
        name = None
        filename = None
        for token in disp.split(";"):
            token = token.strip()
            if token.startswith("name="):
                name = token[5:].strip('"')
            elif token.startswith("filename="):
                filename = token[9:].strip('"')
        if filename is not None:
            files.append((name, filename, content))
        elif name is not None:
            fields[name] = content.decode("utf-8", "replace")
    return fields, files


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        fields, files = parse_multipart(self.headers, body)

        print("\n--- Print job received %s ---" % datetime.now().strftime("%H:%M:%S"))
        print("  path   :", self.path)
        for k, v in fields.items():
            print("  field  : %s = %s" % (k, v))
        if not os.path.isdir(RECEIVED_DIR):
            os.makedirs(RECEIVED_DIR)
        for name, filename, content in files:
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            safe = filename or (name + ".bin")
            dest = os.path.join(RECEIVED_DIR, stamp + "_" + safe)
            with open(dest, "wb") as fh:
                fh.write(content)
            print("  file   : %s (%d bytes) -> %s" % (filename, len(content), dest))

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"OK")

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Virtual Cloud Printer test receiver is running. POST here.")

    def log_message(self, fmt, *args):
        pass  # keep the console clean; we print our own lines


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("Test receiver listening on http://localhost:%d/" % port)
    print("Point a printer's url at:  http://localhost:%d/upload" % port)
    print("Saving uploads to:         %s" % RECEIVED_DIR)
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
