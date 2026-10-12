#!/usr/bin/env python3
"""Build the offline FAT32 formatter packages from src/.

Writes two zips (same content, different file names for the scripts):

  FAT32-Formatter-Offline-Package.zip              script names end in ".txt" so that
                                                    e-mail systems do not block them
  FAT32-Formatter-Offline-Package-ready-to-run.zip  normal script names (USB stick / cloud link)

Each zip holds a SHA256SUMS.txt for its own files. Output is reproducible: fixed
timestamps, sorted entries, fixed permissions.

usage: build_package.py SRC_DIR OUT_DIR
"""
import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = "FAT32-Formatter"
STAMP = (2026, 10, 12, 0, 0, 0)

# (path inside the package, path under src/, convert to Windows line endings, executable bit)
FILES = [
    ("README.txt", "README.txt", True, False),
    ("windows/Format-Fat32.cmd", "windows/Format-Fat32.cmd", True, False),
    ("windows/Format-Fat32.ps1", "windows/Format-Fat32.ps1", True, False),
    ("macos/format-fat32.sh", "macos/format-fat32.sh", False, True),
    ("linux/format-fat32.sh", "linux/format-fat32.sh", False, True),
]
SCRIPT_SUFFIXES = (".cmd", ".ps1", ".sh")


def to_crlf(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


def collect(src: Path, mail_safe: bool):
    """Return [(archive name, bytes, unix mode)] for one variant, without the checksum file."""
    entries = []
    for name, source, crlf, executable in FILES:
        data = (src / source).read_bytes()
        if b"\r\n" in data and not crlf:
            raise SystemExit(f"{source} has Windows line endings but must use Unix ones")
        if crlf:
            data = to_crlf(data)
        is_script = name.endswith(SCRIPT_SUFFIXES)
        if mail_safe and is_script:
            name += ".txt"
            executable = False
        entries.append((name, data, 0o755 if executable else 0o644))
    return entries


def checksum_file(entries) -> bytes:
    lines = [f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data, _ in sorted(entries)]
    return "".join(lines).encode("ascii")


def write_zip(path: Path, entries) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data, mode in sorted(entries):
            info = zipfile.ZipInfo(f"{ROOT}/{name}", date_time=STAMP)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100000 | mode) << 16
            z.writestr(info, data)


def main() -> None:
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for mail_safe, filename in (
        (True, "FAT32-Formatter-Offline-Package.zip"),
        (False, "FAT32-Formatter-Offline-Package-ready-to-run.zip"),
    ):
        entries = collect(src, mail_safe)
        entries.append(("SHA256SUMS.txt", checksum_file(entries), 0o644))
        target = out / filename
        write_zip(target, entries)
        print(f"{target}  {target.stat().st_size} bytes  sha256 {hashlib.sha256(target.read_bytes()).hexdigest()}")
        for name, data, mode in sorted(entries):
            print(f"    {ROOT}/{name:<40} {len(data):>7} bytes  mode {mode:o}")


if __name__ == "__main__":
    main()
