# Offline FAT32 flash-drive formatter

Formats 32 GB USB flash drives as FAT32 on Windows, macOS and Linux. It works offline: no downloads, nothing to install. It erases the drive you choose, so it lists only USB drives of about 25-35 GB, never your own drive, and waits for you to type `ERASE`.

This folder is self-contained and unrelated to the Browserless plugin in the rest of the repository.

## The package

| File | What it is |
| --- | --- |
| [`dist/FAT32-Formatter-Offline-Package.zip`](dist/FAT32-Formatter-Offline-Package.zip) | The email attachment. Script names end in `.txt` so Gmail and Outlook.com do not block them; the `README.txt` inside shows how to remove that. |
| [`dist/FAT32-Formatter-Offline-Package-ready-to-run.zip`](dist/FAT32-Formatter-Offline-Package-ready-to-run.zip) | The same files with normal names, for a USB stick or a cloud link. |
| [`dist/Email-Draft-to-Wheelzy.eml`](dist/Email-Draft-to-Wheelzy.eml) | Unsent draft to Wheelzy@hotmail.com with the first zip attached. Outlook and Thunderbird open it as an editable draft. |
| [`dist/Email-Draft-to-Wheelzy.txt`](dist/Email-Draft-to-Wheelzy.txt) | The draft text for copy and paste, plus a `mailto:` link for a phone. |

SHA-256 of the zips:

```
9dd4004e57f93d81801bc0b25e88fa7695f6d33a7949eeb3714720697c41bdf7  FAT32-Formatter-Offline-Package.zip
f7e73769984a0f428a4950dab5943d7c74d147f7fd4b22634d452926c67b958c  FAT32-Formatter-Offline-Package-ready-to-run.zip
```

The readable scripts are in [`src/`](src). [`src/README.txt`](src/README.txt) is the user guide that ships inside the zips.

## Quick start on Windows

1. Extract the zip. If the script names end in `.txt`, take `.txt` off `Format-Fat32.cmd.txt` and `Format-Fat32.ps1.txt` in the `windows` folder.
2. Plug in the flash drive(s) and double-click `Format-Fat32.cmd`. Click Yes when Windows asks for permission.
3. Type the drive number (or `ALL`), then type `ERASE`.

Start with `Format-Fat32.cmd -DryRun`: it only lists the drives it would offer. Mac and Linux steps are in `src/README.txt`.

## Status

The Linux script was tested on real block devices (loop devices). The Windows script and launcher, and the macOS script, have **not** run on a real Windows PC or Mac yet: Windows was checked with simulated Storage cmdlets plus PSScriptAnalyzer against Windows PowerShell 5.1 profiles, and macOS against a simulated `diskutil` on bash 5 and on bash 3.2. Run the dry-run option first on real hardware.

## Rebuild and re-check

```bash
python3 build_package.py src dist
python3 build_eml.py dist/FAT32-Formatter-Offline-Package.zip dist
```

The zips rebuild byte-for-byte from `src/`. The `.eml` differs on a rebuild only by its random MIME boundary.

The test suites are meant for a **disposable Linux VM**: they create loop devices and use `sudo` to temporarily rename `sfdisk` and `mkfs.vfat`.

```bash
PWSH=/path/to/pwsh BASH32=/path/to/bash-3.2 PSSA_MODULE=/path/to/PSScriptAnalyzer \
  bash tests/run-evidence.sh dist /tmp/fat32-logs
```

They need `sudo`, `dosfstools`, `fdisk`, `parted`, `mtools`, `shellcheck`, and PowerShell 7 with PSScriptAnalyzer. `BASH32` (a bash 3.2 build, the version macOS ships) is optional; without it that step is skipped.
