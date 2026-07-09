# Compliance, Licensing & Privacy

Straight answers for evaluating this tool where documents are **confidential**
(e.g. a pharmaceutical company). Read this alongside `NOTICE`. **This is
engineering guidance, not legal advice — have your legal/compliance and IT
security teams sign off before production use with real data.**

---

## 1. Is it free to use?

**The code in this repo:** yes — MIT licensed, free for commercial use.

**The tools the installer pulls in:** mostly yes, with **one important exception**:

| Component | License | Free for a company? |
|---|---|---|
| This project's scripts | MIT | ✅ Yes |
| uv | Apache-2.0 / MIT | ✅ Yes |
| CPython | PSF | ✅ Yes |
| mfilemon / clawmon (port monitor) | GPL-2.0 | ✅ Yes for internal use (unmodified) |
| FastAPI/Uvicorn (simulator only) | MIT/BSD | ✅ Yes |
| **Ghostscript** | **AGPL v3 or paid commercial** | ⚠️ **Needs a decision** |

**Ghostscript is the catch.** It's dual-licensed by Artifex: the free build is
**AGPL v3**; commercial/proprietary users are expected to buy a commercial
license, and Artifex does enforce this. Ghostscript runs 100% locally and never
transmits your documents — so this is a **licensing/legal** question, not a
privacy one. For a pharmaceutical company the clean options are:

1. **Buy an Artifex commercial license** (removes all ambiguity) —
   <https://artifex.com/licensing/>; **or**
2. Have legal accept AGPL for internal, unmodified, non-distributed use; **or**
3. Replace the PDF-conversion step (send raw PostScript, or use a
   commercially-licensed converter/PDF printer driver).

---

## 2. Regulatory considerations (pharma-specific)

This tool is **not** a validated, certified, or GxP-ready system out of the box.
Depending on what these documents are, the following may apply:

- **21 CFR Part 11 / EU Annex 11 (electronic records).** If the printed
  documents are GxP records (batch records, QC, regulatory submissions), the
  system that creates/transmits them typically needs **Computerized System
  Validation (CSV)** — IQ/OQ/PQ, documented audit trails, access control, and
  data-integrity controls (**ALCOA+**). This tool provides basic logging only;
  it is **not** a Part 11 audit trail. Treat it as infrastructure your
  validation process must wrap, not as validated software.
- **Data integrity.** There is a brief window where the job exists as a `.ps`
  and a `.pdf` on the local disk (in the ACL-locked `spool\` / `failed\`). Failed
  uploads are retained in `failed\` (good for "no data loss") but that means
  confidential PDFs can persist on disk until cleared — factor this into your
  data-handling SOPs.
- **GDPR / HIPAA / privacy law.** If documents contain personal or patient data,
  the destination endpoint, its hosting location, retention, and access controls
  fall under your data-protection obligations. The simulator stores files
  unencrypted on disk and is for testing only.
- **Change control.** Because the installer downloads current versions of uv,
  Ghostscript, and mfilemon at install time, versions aren't pinned. For a
  validated environment, pre-stage fixed, approved versions instead of
  downloading, and record them.

---

## 3. Privacy / data-flow — what actually happens to a document

```
document → PostScript (in RAM + Windows spool) → .ps on disk (ACL-locked)
        → Ghostscript → .pdf on disk (ACL-locked) → HTTPS POST → your URL
        → temp files deleted on success (kept in failed\ on failure)
```

- **In transit:** HTTPS with certificate validation is the default
  (`verify_tls: true`). For confidential data, **only ever use `https://` URLs
  and never set `verify_tls: false`** outside local testing.
- **At rest (local):** the working folder `%ProgramData%\VirtualCloudPrinter` is
  locked to **SYSTEM + Administrators** by the installer. Deletion of temp files
  is normal deletion (recoverable by forensic tools) — for high-sensitivity data,
  put it on an encrypted volume (BitLocker) and/or add secure-wipe.
- **Windows spooler:** independent of this tool, Windows itself briefly writes
  spool files under `C:\Windows\System32\spool\PRINTERS`. That's inherent to all
  Windows printing; your endpoint-hardening standards apply.
- **Third parties / telemetry:** **none.** `upload.py` is a single, auditable,
  standard-library file that sends **only** to the URL you configure. Ghostscript,
  mfilemon, uv, and Python do not exfiltrate your documents. The only outbound
  destination for your data is your own endpoint.

---

## 4. Can you "fully trust" it?

Honest answer: **don't fully trust any software blindly — including this.** What
you *can* rely on, and what you must do:

**Strengths you can verify**
- The uploader is ~300 lines of readable, dependency-free Python — auditable in
  an afternoon. It POSTs only to your configured URL.
- No hidden network calls, no telemetry, no cloud middleman.
- The port monitor is open source (GPL) and its exact behavior was read from
  source when building this; you can audit it too.
- Runtime files are ACL-restricted and the SYSTEM-privilege-escalation vector
  was specifically closed.

**What you must still do for a pharma-grade deployment**
- [ ] Legal review of the **Ghostscript** license (or buy the commercial one).
- [ ] IT security review + approval of every third-party binary; **pin approved
      versions** rather than downloading at install time.
- [ ] Use **HTTPS with a valid certificate** end-to-end; keep `verify_tls: true`.
- [ ] Add authentication to the endpoint (API key / mTLS) — the simulator shows
      the API-key-in-link pattern; production should use headers/mTLS over TLS.
- [ ] Put the working folder on an **encrypted** disk; define retention/secure-
      wipe for `failed\`.
- [ ] If documents are GxP/Part 11 records, run it through your **CSV** process;
      this tool is not a substitute for a validated system or a compliant audit
      trail.
- [ ] Restrict who can create printers / edit `config.json` (admin only — already
      enforced by the ACL, but confirm in your environment).

**Bottom line:** it's a transparent, self-contained, no-middleman tool suitable
for internal use once your security and legal teams have reviewed the Ghostscript
licensing and endpoint security. It is *not* pre-validated for regulated GxP
recordkeeping — that remains your organization's process.
