#!/usr/bin/env python3
"""Write the e-mail draft for the offline FAT32 formatter package.

Produces, next to each other:
  Email-Draft-to-Wheelzy.eml   an UNSENT message (header X-Unsent: 1) with the zip attached.
                               Outlook and Thunderbird open it as an editable draft.
  Email-Draft-to-Wheelzy.txt   the same text for copy and paste, plus a mailto: link
                               for phones (a mailto: link cannot carry an attachment).

Nothing is sent. There is no From or Date header: the mail program fills those in.

usage: build_eml.py PACKAGE_ZIP OUT_DIR
"""
import sys
from email.message import EmailMessage
from email import policy
from pathlib import Path
from urllib.parse import quote

TO = "Wheelzy@hotmail.com"
SUBJECT = "Offline FAT32 formatter for 32 GB flash drives (package attached)"

BODY = """\
Hi,

Attached is an offline tool that formats 32 GB USB flash drives as FAT32.
It needs no internet connection and no installation: it only uses tools that
already come with Windows, macOS and Linux.

WARNING: everything on a drive you choose is erased and cannot be recovered.
The tool only lists USB drives of about 25-35 GB, never the computer's own
drive, and asks you to type ERASE before it changes anything.

WINDOWS (most common)
  1. Save FAT32-Formatter-Offline-Package.zip. Right-click it, choose
     Properties and tick "Unblock" if you see it, then Extract All.
  2. Open the "windows" folder. Take ".txt" off the end of the two file names:
         Format-Fat32.cmd.txt  ->  Format-Fat32.cmd
         Format-Fat32.ps1.txt  ->  Format-Fat32.ps1
     (The ".txt" was added only so e-mail systems do not block the scripts.)
  3. Plug in the flash drive(s) and double-click Format-Fat32.cmd.
     Click Yes when Windows asks for permission.
  4. Type the number of the drive (or ALL) and press Enter, then type ERASE
     and press Enter.
  Not sure? Start it with -DryRun first (Format-Fat32.cmd -DryRun in a
  Command Prompt). That only lists the drives and changes nothing.

MAC AND LINUX
  The steps are in README.txt inside the zip. In short: take ".txt" off
  format-fat32.sh.txt, then run  sudo bash format-fat32.sh

CHECKING THE FILES
  SHA256SUMS.txt lists a fingerprint for every file; README.txt shows how to
  compare them.

WHAT IS IN THE ZIP
  README.txt
  SHA256SUMS.txt
  windows\\Format-Fat32.cmd.txt
  windows\\Format-Fat32.ps1.txt
  macos/format-fat32.sh.txt
  linux/format-fat32.sh.txt

Thanks
"""

SHORT_BODY = (
    "Hi,\r\n\r\nAttached is an offline tool that formats 32 GB USB flash drives as FAT32 "
    "(no internet needed). Open README.txt inside the zip for the steps.\r\n\r\n"
    "WARNING: it erases the drive you choose.\r\n\r\nThanks\r\n"
)


def main() -> None:
    zip_path, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    data = zip_path.read_bytes()

    msg = EmailMessage(policy=policy.SMTP)
    msg["To"] = TO
    msg["Subject"] = SUBJECT
    msg["X-Unsent"] = "1"
    msg["MIME-Version"] = "1.0"
    msg.set_content(BODY, charset="us-ascii", cte="7bit")
    msg.add_attachment(data, maintype="application", subtype="zip", filename=zip_path.name)

    eml = out / "Email-Draft-to-Wheelzy.eml"
    eml.write_bytes(msg.as_bytes(policy=policy.SMTP))

    mailto = f"mailto:{TO}?subject={quote(SUBJECT)}&body={quote(SHORT_BODY)}"
    txt = out / "Email-Draft-to-Wheelzy.txt"
    txt.write_text(
        f"To:       {TO}\n"
        f"Subject:  {SUBJECT}\n"
        f"Attach:   {zip_path.name}  ({len(data)} bytes)\n"
        "\n"
        "---------------------------------------------------------------\n"
        f"{BODY}"
        "---------------------------------------------------------------\n"
        "\n"
        "On a phone: tap this link for a pre-addressed message, then attach the zip.\n"
        "(A link cannot carry an attachment, so its text is shorter.)\n"
        f"{mailto}\n",
        encoding="ascii",
    )
    print(f"wrote {eml} ({eml.stat().st_size} bytes)")
    print(f"wrote {txt} ({txt.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
