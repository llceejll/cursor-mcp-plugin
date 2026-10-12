#!/usr/bin/env python3
"""Checks the e-mail draft the way a mail program will read it.

usage: validate_eml.py DRAFT.eml PACKAGE.zip
"""
import hashlib
import io
import sys
import zipfile
from email import policy
from email.parser import BytesParser
from pathlib import Path

eml_path, zip_path = Path(sys.argv[1]), Path(sys.argv[2])
raw = eml_path.read_bytes()
msg = BytesParser(policy=policy.default).parsebytes(raw)

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("PASS  " if ok else "FAIL  ") + name + (f" ({detail})" if detail else ""))
    if not ok:
        failures += 1


check("recipient is exactly Wheelzy@hotmail.com", [a.addr_spec for a in msg["To"].addresses] == ["Wheelzy@hotmail.com"], msg["To"])
check("only one recipient, no Cc or Bcc", msg["Cc"] is None and msg["Bcc"] is None and len(msg["To"].addresses) == 1)
check("subject present", bool(msg["Subject"]), msg["Subject"])
check("marked unsent (X-Unsent: 1) so mail programs open it as a draft", msg["X-Unsent"] == "1")
check("no From or Date header (the mail program fills them in; nothing pretends to be sent)", msg["From"] is None and msg["Date"] is None)
check("multipart/mixed", msg.get_content_type() == "multipart/mixed", msg.get_content_type())
check("Windows (CRLF) line endings throughout", raw.count(b"\r\n") == raw.count(b"\n"))

parts = list(msg.iter_parts())
check("exactly two parts: text and attachment", len(parts) == 2, ", ".join(p.get_content_type() for p in parts))
body = msg.get_body(preferencelist=("plain",))
check("plain-text body present", body is not None)
text = body.get_content()
for needle in ("WARNING: everything on a drive you choose is erased", "Format-Fat32.cmd.txt", "README.txt", "SHA256SUMS.txt", "ERASE", "-DryRun"):
    check(f"body mentions {needle!r}", needle in text)
check("body is plain ASCII", all(ord(c) < 128 for c in text))

attachments = list(msg.iter_attachments())
check("one attachment", len(attachments) == 1)
att = attachments[0]
check("attachment name", att.get_filename() == zip_path.name, att.get_filename())
check("attachment type application/zip", att.get_content_type() == "application/zip", att.get_content_type())
payload = att.get_content()
check("attachment bytes identical to the package zip (sha256)", hashlib.sha256(payload).hexdigest() == hashlib.sha256(zip_path.read_bytes()).hexdigest(), hashlib.sha256(payload).hexdigest()[:16] + "...")
z = zipfile.ZipFile(io.BytesIO(payload))
check("attached zip opens and passes its CRC test", z.testzip() is None)
names = sorted(z.namelist())
check("attached zip has no file a mail system would block", not any(n.lower().endswith((".ps1", ".cmd", ".bat", ".sh", ".exe", ".js", ".vbs", ".msi", ".scr", ".lnk", ".jar")) for n in names), ", ".join(n.split("/", 1)[1] for n in names))
check("every file the body lists is in the zip", all(any(n.endswith(x) for n in names) for x in ("README.txt", "SHA256SUMS.txt", "windows/Format-Fat32.cmd.txt", "windows/Format-Fat32.ps1.txt", "macos/format-fat32.sh.txt", "linux/format-fat32.sh.txt")))
check("message is small (Hotmail limit is far larger)", len(raw) < 200_000, f"{len(raw)} bytes")

print(f"\n{'ALL CHECKS PASSED' if failures == 0 else str(failures) + ' CHECK(S) FAILED'}")
sys.exit(1 if failures else 0)
