FAT32 FLASH DRIVE FORMATTER (OFFLINE)                       version 1.0.0
=====================================================================

Formats USB flash drives of about 32 GB as FAT32. It works with no
internet connection and nothing has to be installed: it only uses tools
that already come with Windows, macOS and Linux.

   *** EVERYTHING ON THE DRIVE YOU CHOOSE IS ERASED FOR GOOD. ***

Not sure about something? Run the tool with -DryRun (Windows) or
--dry-run (Mac, Linux) first. That only LISTS the drives it would offer
and changes nothing.


WHAT IS IN THIS FOLDER
----------------------
  README.txt                  this file
  SHA256SUMS.txt              checksums, to check the files are undamaged
  windows\Format-Fat32.cmd    Windows: double-click this
  windows\Format-Fat32.ps1    Windows: the tool itself (the .cmd starts it)
  macos/format-fat32.sh       Mac
  linux/format-fat32.sh       Linux

If the names in your copy end in ".txt" (for example Format-Fat32.ps1.txt)
that is on purpose: e-mail systems often block script files, so ".txt" was
added for the trip. Take it off first (see STEP 0 below). Everything else
is the same.


HOW THE TOOL CHOOSES DRIVES (so you can trust the list)
-------------------------------------------------------
  * Only USB drives between 25 GB and 35 GB are shown. (A drive sold as
    "32 GB" is really about 28-32 GB.) Change the range with -MinSizeGB /
    -MaxSizeGB (Windows) or --min-gb / --max-gb (Mac, Linux).
  * The drive your computer runs from is never shown, and neither is the
    drive this tool is running from. Copy the tool to the computer first.
  * Nothing happens until you type ERASE.
  * Every drive is checked again right before it is erased. If it was
    swapped or changed in the meantime, it is skipped.
  * Each drive gets ONE FAT32 volume using the whole drive, with an MBR
    partition table. That is the layout almost every car stereo, TV,
    camera and game console understands.


STEP 0 - ONLY IF THE FILE NAMES END IN ".txt"
---------------------------------------------
  Windows: open the "windows" folder. In File Explorer choose
           View > Show > File name extensions, then rename
               Format-Fat32.cmd.txt  ->  Format-Fat32.cmd
               Format-Fat32.ps1.txt  ->  Format-Fat32.ps1
           (click Yes if Windows asks whether to change the extension).

           Prefer to copy and paste? Open the folder in File Explorer, click
           the address bar, type  powershell  and press Enter, then paste:

   Get-ChildItem -Recurse -Filter '*.txt' | Where-Object { $_.Name -match '\.(ps1|cmd|sh)\.txt$' } | Rename-Item -NewName { $_.Name -replace '\.txt$','' }

  Mac / Linux: in a terminal, inside the unzipped folder:

   for f in */*.sh.txt; do mv "$f" "${f%.txt}"; done


WINDOWS 10 / 11
---------------
  1. Copy the unzipped folder to the computer (the Desktop is fine).
     If you got a .zip: right-click it > Properties > tick "Unblock" if it
     is shown > OK, then right-click > Extract All.
  2. Plug in the flash drive(s).
  3. Open the "windows" folder and double-click  Format-Fat32.cmd
     Click Yes when Windows asks for permission to continue.
  4. You see a numbered list. Check the Size and the "On it now" column to
     be sure it is the right drive. Type its number (for example 1), or
     1,2 for two drives, or ALL, and press Enter.
  5. Type  ERASE  (capital letters) and press Enter.
  6. Wait for "done" and the Summary. Eject the drive in the usual way.
     Plug in the next drives and press Enter to do them too, or type Q.

  "Windows protected your PC" (SmartScreen) can appear for downloaded
  scripts. If you trust where this came from, click More info > Run anyway.
  Compare the checksums first (see CHECKING THE FILES).

  Extra options, typed after the file name in a Command Prompt:
      Format-Fat32.cmd -DryRun                list only, change nothing
      Format-Fat32.cmd -Label MUSIC           name the drive MUSIC (max 11 characters)
      Format-Fat32.cmd -Full                  slow full format (checks every sector)
      Format-Fat32.cmd -MinSizeGB 14 -MaxSizeGB 17      show 16 GB drives instead

  If you cannot rename the files at all, open "Windows PowerShell (Admin)"
  from the Start menu, go to the windows folder with cd, and run this one
  line (it reads the .txt copy directly):

   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '.\Format-Fat32.ps1.txt')))"

  To pass options with that line, add them after the closing brackets, for
  example  -DryRun  or  -Label MUSIC


MAC
---
  1. Plug in the flash drive(s).
  2. Open Terminal (Applications > Utilities). Type  cd  and a space, drag
     the "macos" folder from Finder into the Terminal window, press Enter.
  3. Run:   sudo bash format-fat32.sh
     Your password is asked; nothing shows while you type it.
  4. Choose the drive number, then type ERASE, exactly as on Windows.
  Options:  --dry-run   --label NAME   --min-gb N   --max-gb N
  Only external USB drives are offered; the Mac's own disk never is.
  The Mac version does a quick format only.


LINUX
-----
  1. Plug in the flash drive(s).
  2. In a terminal, go to the "linux" folder and run:
         sudo bash format-fat32.sh
  3. Choose the drive number, then type ERASE, exactly as on Windows.
  Options:  --dry-run   --label NAME   --min-gb N   --max-gb N   --full
  It needs two things that almost every desktop Linux already has:
      mkfs.vfat   (package "dosfstools")
      sfdisk or parted   (package "fdisk" or "parted")
  If one is missing the tool says which, before it changes anything.
  Offline? Install the missing package from your distribution disc or
  package cache.
  --full writes zeros over the whole drive first. It is slow but also wipes
  the old files for good.


CHECKING THE FILES (optional)
-----------------------------
  SHA256SUMS.txt lists a fingerprint for every file. Check them BEFORE you
  take any ".txt" off the names, so the names still match the list.
  Windows (PowerShell, inside the folder):
      Get-FileHash -Algorithm SHA256 -Path .\windows\*, .\macos\*, .\linux\* | Format-Table Hash, Path
  and compare each Hash with the matching line (hashes are not case sensitive).
  Mac:     shasum -a 256 -c SHA256SUMS.txt
  Linux:   sha256sum -c SHA256SUMS.txt


IF SOMETHING GOES WRONG
-----------------------
  "No USB flash drives ... were found"
      Unplug and plug the drive again, try another USB port, then press
      Enter to scan again. The tool also lists USB drives it ignored and
      why (too small, too large, ...). A drive that is not really 25-35 GB
      needs -MinSizeGB / -MaxSizeGB (Windows) or --min-gb / --max-gb.
  "Windows cannot create a FAT32 volume larger than 32 GB"
      Windows' own tools refuse FAT32 above 32 GB. Real 32 GB drives are
      fine; a larger or mislabelled drive will fail with this message.
  "Access is denied" / "in use"
      Close File Explorer windows and any program using the drive, unplug
      it, plug it in again, and retry.
  "The drive is write-protected"
      Look for a small lock switch on the drive and slide it to unlocked.
  The window closes before you can read it
      Start it with Format-Fat32.cmd (it keeps the window open), or run the
      .ps1 from a PowerShell window you opened yourself.
  "Access denied" while the drives are being listed (even with -DryRun)
      Right-click the Start button > "Windows PowerShell (Admin)" (or
      "Terminal (Admin)"), go to the windows folder with cd, and run:
          .\Format-Fat32.cmd -DryRun
  "Running scripts is disabled on this system"
      On a work or school computer this is a security rule set by whoever
      manages it. Ask them, or use a personal computer. (Format-Fat32.cmd
      already handles the normal home-computer setting.)

What this tool does NOT do: it does not make drives bigger than 32 GB
FAT32 on Windows, it does not format as exFAT or NTFS, and a quick format
is not a secure wipe. Use -Full / --full to overwrite the old data.
