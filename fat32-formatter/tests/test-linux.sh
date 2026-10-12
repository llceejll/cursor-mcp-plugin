#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2024  # test-harness idioms: pass/fail counters, PowerShell snippets in single quotes, redirects that must stay owned by the caller
# End-to-end test of linux/format-fat32.sh against REAL block devices (loop devices).
#
# No real disk is ever written: every destructive run goes through tool_on(), which
# refuses any target that is not a loop device this harness created from a sparse
# file under $WORK. Refusals against the real system disk use --dry-run only.
#
# This test VM's kernel cannot mount vfat, so the new FAT32 volumes are verified with
# independent user-space readers instead: blkid, fsck.vfat, mtools, and a boot-sector
# check against the FAT32 rules Windows uses. ext4 (mountable here) is used for the
# tests that need a mounted drive.
#
#   bash test-linux.sh /path/to/format-fat32.sh [workdir]
set -u
TOOL="$(readlink -f "${1:?usage: test-linux.sh /path/to/format-fat32.sh [workdir]}")"
WORK="${2:-/tmp/fat32-dev/work}"
mkdir -p "$WORK/mnt" "$WORK/fakebin"
WORK="$(readlink -f "$WORK")"

PASS=0
FAIL=0
LOOPS=()
REPLY=""

section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1 (= $3)"; else bad "$1: got '$2', wanted '$3'"; fi; }
expect_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: output lacked '$3'" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) bad "$1: output unexpectedly had '$3'" ;; *) ok "$1" ;; esac; }
mtl() { sudo env MTOOLS_SKIP_CHECK=1 "$@"; }

cleanup() {
  local d p t
  for d in ${LOOPS[@]+"${LOOPS[@]}"}; do
    for p in "$d" "${d}"p*; do
      [ -b "$p" ] || continue
      findmnt -rn -o TARGET -S "$p" 2>/dev/null | while read -r t; do sudo umount "$t" 2>/dev/null; done
    done
    sudo losetup -d "$d" 2>/dev/null
  done
  sudo umount /cdrom 2>/dev/null
  sudo rmdir /cdrom 2>/dev/null
  sudo mv /usr/sbin/sfdisk.hidden /usr/sbin/sfdisk 2>/dev/null
  sudo mv /usr/sbin/mkfs.vfat.hidden /usr/sbin/mkfs.vfat 2>/dev/null
  sudo mv /usr/sbin/mkfs.fat.hidden /usr/sbin/mkfs.fat 2>/dev/null
  rm -f "$WORK"/*.img
}
trap cleanup EXIT

new_loop() { # new_loop NAME SIZE -> REPLY=/dev/loopN
  local img="$WORK/$1.img"
  rm -f "$img"
  truncate -s "$2" "$img"
  REPLY="$(sudo losetup -f --show "$img")"
  LOOPS+=("$REPLY")
}

only_test_loop() { # a test loop device, or a partition of one
  local l
  for l in "${LOOPS[@]}"; do
    case "$1" in "$l"|"$l"p[0-9]*) return 0 ;; esac
  done
  echo "HARNESS REFUSES: $1 is not a test loop device"
  exit 99
}

tool_on() { # tool_on "<stdin>" DEV [tool args...]   (real run, as root)
  local input="$1" dev="$2"
  shift 2
  only_test_loop "$dev"
  printf '%b' "$input" | sudo bash "$TOOL" --device "$dev" --allow-non-usb "$@"
}

fs_type() { sudo blkid -p -o value -s TYPE "$1" 2>/dev/null; }
fs_label() { sudo blkid -p -o value -s LABEL "$1" 2>/dev/null; }
fat_version() { sudo blkid -p -o value -s VERSION "$1" 2>/dev/null; }

# This VM's loop driver does no kernel partition scanning, so add nodes by hand.
add_partition_nodes() { sudo partprobe "$1" >/dev/null 2>&1 || sudo partx -a "$1" >/dev/null 2>&1; sleep 1; }

seed_whole_ext4() { # old data written straight onto the device
  only_test_loop "$1"
  sudo mkfs.ext4 -q -F -L OLDDATA -O ^has_journal -N 64 "$1" >/dev/null 2>&1
  sudo mount "$1" "$WORK/mnt/seed" && echo "precious" | sudo tee "$WORK/mnt/seed/old-photo.txt" >/dev/null
  sudo umount "$WORK/mnt/seed"
}

seed_partitioned_ext4() { # old MBR partition holding ext4
  only_test_loop "$1"
  printf 'label: dos\nstart=2048, type=83\n' | sudo sfdisk --quiet "$1" >/dev/null 2>&1
  add_partition_nodes "$1"
  sudo mkfs.ext4 -q -F -L OLDPART -O ^has_journal -N 64 "${1}p1" >/dev/null 2>&1
}

# Boot-sector check against the FAT32 rules (Microsoft FAT spec): this is how Windows
# decides a volume is FAT32 and whether it can be read.
bootsector_report() { # bootsector_report PARTITION -> prints facts, last line "RESULT ok|bad"
  local part="$1" sectors
  sectors="$(sudo blockdev --getsz "$part")"
  sudo dd if="$part" bs=512 count=1 2>/dev/null > "$WORK/bootsector.bin"
  python3 - "$WORK/bootsector.bin" "$sectors" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
part_sectors = int(sys.argv[2])
bps, spc, rsv, nfats, root_ent, tot16 = struct.unpack_from('<HBHBHH', b, 11)
media, fatsz16 = struct.unpack_from('<BH', b, 21)
hidden, tot32, fatsz32 = struct.unpack_from('<III', b, 28)[0], *struct.unpack_from('<II', b, 32)
root_cluster, = struct.unpack_from('<I', b, 44)
fsinfo, backup = struct.unpack_from('<HH', b, 48)
fstype = b[82:90]
sig = struct.unpack_from('<H', b, 510)[0]
data_sectors = tot32 - (rsv + nfats * fatsz32)
clusters = data_sectors // spc
rules = {
    "512 bytes per sector": bps == 512,
    "cluster size is a power of two, 512 B..32 KiB": spc in (1, 2, 4, 8, 16, 32, 64) and bps * spc <= 32768,
    "2 FATs": nfats == 2,
    "no fixed root directory (FAT32)": root_ent == 0 and tot16 == 0 and fatsz16 == 0,
    "media descriptor 0xF8": media == 0xF8,
    "file system fits in the partition (spare sectors: %d, must be < 2048)" % (part_sectors - tot32): 0 <= part_sectors - tot32 < 2048,
    "cluster count >= 65525 (the rule that makes it FAT32)": clusters >= 65525,
    "root directory starts at cluster 2": root_cluster == 2,
    "FSInfo sector 1, backup boot sector 6": fsinfo == 1 and backup == 6,
    "file system type string is 'FAT32   '": fstype == b'FAT32   ',
    "boot signature 0x55AA": sig == 0xAA55,
}
print("  geometry: %d B/sector, %d sectors/cluster (%d KiB clusters), %d reserved, FAT size %d sectors x%d" % (bps, spc, bps * spc // 1024, rsv, fatsz32, nfats))
print("  total %d sectors, %d clusters, hidden sectors %d" % (tot32, clusters, hidden))
bad = 0
for name, good in rules.items():
    print("  [%s] %s" % ("ok" if good else "BAD", name))
    bad += 0 if good else 1
print("RESULT " + ("ok" if bad == 0 else "bad"))
PY
}

mkdir -p "$WORK/mnt/seed" "$WORK/mnt/use" "$WORK/mnt/live" "$WORK/mnt/tool"

echo "Tool under test : $TOOL"
echo "dosfstools      : $(dpkg-query -W -f='${Version}' dosfstools 2>/dev/null)   mtools: $(dpkg-query -W -f='${Version}' mtools 2>/dev/null)"
echo "util-linux      : $(sfdisk --version)"
echo "kernel          : $(uname -sr)  (no vfat driver: results are checked with user-space readers)"
bash -n "$TOOL" && ok "bash -n syntax check"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck is clean" shellcheck -s bash "$TOOL"
fi

# ------------------------------------------------------------------------------
section "1. Setup: three 30 GiB (32.2 GB) fake flash drives, one 100 MB, one 64 GiB"
new_loop usb1 30G; USB1="$REPLY"
new_loop usb2 30G; USB2="$REPLY"
new_loop usb3 30G; USB3="$REPLY"
new_loop tiny 100M; TINY="$REPLY"
new_loop huge 64G; HUGE="$REPLY"
echo "USB1=$USB1  USB2=$USB2  USB3=$USB3  TINY=$TINY  HUGE=$HUGE"
seed_whole_ext4 "$USB1"
seed_partitioned_ext4 "$USB2"
seed_whole_ext4 "$USB3"
expect_eq "USB1 starts as ext4 (old data, no partition table)" "$(fs_type "$USB1")" ext4
expect_eq "USB2 starts with an old ext4 partition" "$(fs_type "${USB2}p1")" ext4
echo "--- before ---"; lsblk -o NAME,SIZE,FSTYPE,LABEL,PTTYPE "$USB1" "$USB2"

# ------------------------------------------------------------------------------
section "2. Dry run and wrong confirmations change nothing"
out="$(sudo bash "$TOOL" --device "$USB1" --allow-non-usb --dry-run 2>&1)"; rc=$?
echo "$out"
expect_eq "dry run exit code" "$rc" 0
expect_contains "dry run says nothing was changed" "$out" "DRY RUN: nothing was changed"
expect_eq "USB1 untouched after dry run" "$(fs_type "$USB1")" ext4

out="$(tool_on 'erase\n' "$USB1" 2>&1)"; rc=$?
echo "$out" | tail -4
expect_contains "lower-case 'erase' cancels" "$out" "Cancelled. Nothing was changed."
expect_eq "USB1 untouched after wrong confirmation" "$(fs_type "$USB1")" ext4

out="$(tool_on '\n' "$USB1" 2>&1)"
expect_contains "empty answer cancels" "$out" "Cancelled. Nothing was changed."
expect_eq "USB1 still ext4" "$(fs_type "$USB1")" ext4

out="$(sudo bash "$TOOL" --device "$USB1" --allow-non-usb </dev/null 2>&1)"
expect_contains "closed stdin cancels instead of erasing" "$out" "Cancelled. Nothing was changed."
expect_eq "USB1 still ext4 after closed stdin" "$(fs_type "$USB1")" ext4

# ------------------------------------------------------------------------------
section "3. Real format of USB1 (typed ERASE, label 'music' becomes MUSIC)"
start=$(date +%s)
out="$(tool_on 'ERASE\n' "$USB1" --label music 2>&1)"; rc=$?
end=$(date +%s)
echo "$out"
echo "(took $((end - start)) s)"
expect_eq "exit code" "$rc" 0
expect_contains "summary says OK" "$out" "OK      $USB1"
P1="${USB1}p1"
check "partition node exists: $P1" test -b "$P1"
expect_eq "blkid TYPE" "$(fs_type "$P1")" vfat
expect_eq "blkid VERSION" "$(fat_version "$P1")" FAT32
expect_eq "label upper-cased" "$(fs_label "$P1")" MUSIC
check "fsck.vfat -n finds no errors" sudo fsck.vfat -n "$P1"
expect_contains "fsck says 32 bit FAT" "$(sudo fsck.vfat -vn "$P1" 2>&1)" "32 bit"
expect_eq "fatlabel" "$(sudo fatlabel "$P1")" MUSIC
expect_eq "partition table type" "$(sudo blkid -p -o value -s PTTYPE "$USB1")" dos
dump="$(sudo sfdisk -d "$USB1")"
echo "$dump"
expect_contains "partition starts at sector 2048" "$dump" "start=        2048"
expect_contains "partition type is 0c (FAT32 LBA)" "$dump" "type=c"
wf="$(sudo wipefs "$USB1" 2>&1)"
expect_contains "disk now carries only an MBR (dos) signature" "$wf" "dos"
expect_lacks "old ext4 signature is gone from the disk" "$wf" ext4
expect_eq "exactly one partition" "$(lsblk -n -r -o TYPE "$USB1" | grep -c part)" 1
parts_end=$(sudo sfdisk -J "$USB1" | python3 -c 'import json,sys; p=json.load(sys.stdin)["partitiontable"]["partitions"][0]; print(p["start"]+p["size"])')
disk_sectors=$(sudo blockdev --getsz "$USB1")
echo "partition ends at sector $parts_end of $disk_sectors"
expect_eq "partition uses the whole drive (sectors left over: $((disk_sectors - parts_end)))" "$([ $((disk_sectors - parts_end)) -lt 2048 ] && echo yes || echo no)" yes
echo "--- after ---"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PTTYPE "$USB1"
sudo fdisk -l "$USB1" 2>/dev/null | sed -n '1,12p'

echo "--- independent check 1: FAT32 boot sector against the Microsoft FAT rules ---"
rep="$(bootsector_report "$P1")"
echo "$rep"
expect_eq "boot sector passes every FAT32 rule" "$(printf '%s\n' "$rep" | tail -1)" "RESULT ok"

echo "--- independent check 2: mtools (a separate FAT implementation) writes and reads files ---"
mtl minfo -i "$P1" :: 2>&1 | sed -n '1,14p'
expect_contains "mtools sees the volume label" "$(mtl mlabel -s -i "$P1" :: 2>&1)" "MUSIC"
head -c 8388608 /dev/urandom > "$WORK/test.bin"
want=$(sha256sum "$WORK/test.bin" | cut -d' ' -f1)
mtl mcopy -i "$P1" "$WORK/test.bin" ::test.bin
sudo sync
mtl mcopy -i "$P1" ::test.bin "$WORK/readback.bin"
got=$(sha256sum "$WORK/readback.bin" | cut -d' ' -f1)
expect_eq "8 MiB file written to the new FAT32 and read back identical" "$got" "$want"
if mtl mdir -i "$P1" :: 2>/dev/null | grep -qiE 'test +bin +8388608'; then ok "directory listing shows test.bin with its 8388608 bytes"; else bad "directory listing does not show test.bin"; fi
if mtl mdir -i "$P1" ::old-photo.txt >/dev/null 2>&1; then bad "old-photo.txt from the previous ext4 is visible on the new FAT32"; else ok "old-photo.txt from the previous ext4 is not on the new FAT32"; fi
check "fsck.vfat still clean after writing a file" sudo fsck.vfat -n "$P1"

# ------------------------------------------------------------------------------
section "4. Batch: USB1 (again, idempotent), USB2 (had partitions) and USB3 in one run"
out="$(printf 'ERASE\n' | sudo bash "$TOOL" --device "$USB1" --device "$USB2" --device "$USB3" --allow-non-usb 2>&1)"; rc=$?
echo "$out" | sed -n '/Summary/,$p'
expect_eq "exit code" "$rc" 0
for d in "$USB1" "$USB2" "$USB3"; do
  expect_eq "$d partition 1 is vfat FAT32" "$(fs_type "${d}p1")/$(fat_version "${d}p1")" vfat/FAT32
  expect_eq "$d label (default)" "$(fs_label "${d}p1")" USB32
  expect_eq "$d passes the boot-sector rules" "$(bootsector_report "${d}p1" | tail -1)" "RESULT ok"
  check "$d fsck.vfat is clean" sudo fsck.vfat -n "${d}p1"
done
if mtl mdir -i "${USB1}p1" ::test.bin >/dev/null 2>&1; then bad "test.bin from the earlier format is still on USB1"; else ok "test.bin from the earlier format is gone from USB1"; fi
expect_lacks "old ext4 partition on USB2 is gone" "$(sudo wipefs "${USB2}p1" 2>&1)" ext4
expect_eq "USB3 (old ext4 on the raw device) is now partitioned" "$(sudo blkid -p -o value -s PTTYPE "$USB3")" dos

# ------------------------------------------------------------------------------
section "5. A mounted drive is unmounted first (ext4 stands in: this kernel cannot mount vfat)"
sudo mkfs.ext4 -q -F -L LIVE -O ^has_journal -N 64 "${USB1}p1" >/dev/null 2>&1
sudo mount "${USB1}p1" "$WORK/mnt/live"
if mountpoint -q "$WORK/mnt/live"; then ok "USB1p1 really is mounted before the run"; else bad "setup failed: USB1p1 is not mounted"; fi
out="$(tool_on 'ERASE\n' "$USB1" --label "my usb" 2>&1)"; rc=$?
echo "$out" | sed -n '/unmounting/p;/Summary/,$p'
expect_eq "exit code" "$rc" 0
expect_contains "the tool unmounted it" "$out" "unmounting..."
if mountpoint -q "$WORK/mnt/live"; then bad "the old mount is still there"; else ok "the old mount is gone"; fi
expect_eq "USB1p1 is now FAT32" "$(fs_type "${USB1}p1")/$(fat_version "${USB1}p1")" vfat/FAT32
expect_eq "label with a space, upper-cased" "$(fs_label "${USB1}p1")" "MY USB"

# ------------------------------------------------------------------------------
section "6. Refusals (every one of these must fail BEFORE touching anything)"
root_src="$(findmnt -n -o SOURCE /)"
root_disk="$(lsblk -s -n -r -p -o NAME,TYPE "${root_src%%\[*}" | awk '$2 == "disk" { print $1; exit }')"
echo "system disk here: $root_disk (root is on $root_src)"

snap1="$(sudo head -c 4194304 "$TINY" | sha256sum)"
out="$(tool_on 'ERASE\n' "$TINY" 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "100 MB drive: exit code" "$rc" 1
expect_contains "100 MB drive: size message" "$out" "outside 25-35 GB"
expect_eq "100 MB drive: first 4 MiB unchanged" "$(sudo head -c 4194304 "$TINY" | sha256sum)" "$snap1"

out="$(tool_on 'ERASE\n' "$HUGE" 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "64 GiB drive: exit code" "$rc" 1
expect_contains "64 GiB drive: size message" "$out" "outside 25-35 GB"

out="$(tool_on 'ERASE\n' "${USB1}p1" 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "partition instead of drive: exit code" "$rc" 1
expect_contains "partition instead of drive: message" "$out" "not a whole drive"

out="$(sudo bash "$TOOL" --device /dev/does-not-exist --allow-non-usb --dry-run 2>&1)"; rc=$?
expect_eq "missing device: exit code" "$rc" 1
expect_contains "missing device: message" "$out" "not a block device"

out="$(sudo bash "$TOOL" --device "$USB1" --dry-run 2>&1)"; rc=$?
expect_eq "loop device without --allow-non-usb: exit code" "$rc" 1

# a real, non-USB, whole disk (dry run => harmless): the USB-only rule must stop it
out="$(sudo bash "$TOOL" --device "$root_disk" --min-gb 1 --max-gb 100000 --dry-run 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "non-USB disk without --allow-non-usb: exit code" "$rc" 1
expect_contains "non-USB disk without --allow-non-usb: message" "$out" "not a USB drive"

# the real system disk, size range widened and USB rule waived so ONLY the system-disk rule can stop it
out="$(sudo bash "$TOOL" --device "$root_disk" --allow-non-usb --min-gb 1 --max-gb 100000 --dry-run 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "system disk: exit code" "$rc" 1
expect_contains "system disk: refused because it holds the running system" "$out" "holds the running system or this tool"

# a loop device mounted at /cdrom (a protected mount point, as on live media)
sudo mkdir -p /cdrom
sudo mount "$USB3" /cdrom 2>/dev/null || { sudo mkfs.ext4 -q -F -O ^has_journal -N 64 "$USB3" >/dev/null 2>&1; sudo mount "$USB3" /cdrom; }
if mountpoint -q /cdrom; then ok "setup: loop drive really is mounted at /cdrom"; else bad "setup: /cdrom mount failed"; fi
out="$(sudo bash "$TOOL" --device "$USB3" --allow-non-usb --dry-run 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "drive mounted at /cdrom: exit code" "$rc" 1
expect_contains "drive mounted at /cdrom: refused as system" "$out" "holds the running system or this tool"
sudo umount /cdrom

# the tool running from the very drive that would be erased: (a) FS on the raw device, (b) FS on a partition
sudo mkfs.ext4 -q -F -O ^has_journal -N 64 "$USB3" >/dev/null 2>&1
sudo mount "$USB3" "$WORK/mnt/tool"
if mountpoint -q "$WORK/mnt/tool"; then ok "setup: tool copy is on a mounted drive (whole-device file system)"; else bad "setup: mount failed"; fi
sudo cp "$TOOL" "$WORK/mnt/tool/format-fat32.sh"
out="$(sudo bash "$WORK/mnt/tool/format-fat32.sh" --device "$USB3" --allow-non-usb --dry-run 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "tool running from the target drive (raw): exit code" "$rc" 1
expect_contains "tool running from the target drive (raw): refused" "$out" "holds the running system or this tool"
sudo umount "$WORK/mnt/tool"

sudo mkfs.ext4 -q -F -L TOOLDRIVE -O ^has_journal -N 64 "${USB2}p1" >/dev/null 2>&1
sudo mount "${USB2}p1" "$WORK/mnt/tool"
if mountpoint -q "$WORK/mnt/tool"; then ok "setup: tool copy is on a mounted partition"; else bad "setup: mount failed"; fi
sudo cp "$TOOL" "$WORK/mnt/tool/format-fat32.sh"
out="$(sudo bash "$WORK/mnt/tool/format-fat32.sh" --device "$USB2" --allow-non-usb --dry-run 2>&1)"; rc=$?
echo "$out" | tail -2
expect_eq "tool running from a partition of the target drive: exit code" "$rc" 1
expect_contains "tool running from a partition of the target drive: refused" "$out" "holds the running system or this tool"
sudo umount "$WORK/mnt/tool"

# ------------------------------------------------------------------------------
section "7. Guard against a drive that changed between listing and erasing"
before="$(sudo blkid -p -o export "${USB2}p1" | sort | tr '\n' ' ')"
echo "USB2p1 before: $before"
sudo bash -c "
  source '$TOOL'
  ALLOW_NON_USB=1; MKFS=\$(command -v mkfs.vfat)
  PROTECTED=\"\$(protected_disks | sort -u)\"
  check_disk '$USB2' || { echo \"check_disk failed: \$REASON\"; exit 3; }
  good_size=\$D_SIZE
  format_one '$USB2' \$((good_size + 512)) '' ; echo \"wrong size  -> \${RES_LINE[0]:-?}\"
  format_one '$USB2' \"\$good_size\" 'SERIAL-OF-ANOTHER-DRIVE' ; echo \"wrong serial -> \${RES_LINE[1]:-?}\"
" 2>&1 | tee "$WORK/guard.txt"
expect_contains "size mismatch is refused" "$(cat "$WORK/guard.txt")" "wrong size  -> $USB2  FAILED: skipped - the drive changed since it was listed"
expect_contains "serial mismatch is refused" "$(cat "$WORK/guard.txt")" "wrong serial -> $USB2  FAILED: skipped - the drive changed since it was listed"
expect_eq "USB2p1 completely unchanged (nothing erased)" "$(sudo blkid -p -o export "${USB2}p1" | sort | tr '\n' ' ')" "$before"

# ------------------------------------------------------------------------------
section "8. Full format (--full) writes zeros everywhere first (100 MB drive, range widened)"
sudo bash -c "yes 'JUNKJUNKJUNKJUNK' | head -c 104857600 > $TINY" 2>/dev/null
before_nonzero=$(sudo head -c 104857600 "$TINY" | tr -d '\0' | wc -c)
out="$(tool_on 'ERASE\n' "$TINY" --full --min-gb 0.05 --max-gb 0.2 --label tiny 2>&1)"; rc=$?
echo "$out" | sed -n '/full format/p;/Summary/,$p'
expect_eq "exit code" "$rc" 0
expect_eq "TINY is FAT32" "$(fs_type "${TINY}p1")/$(fat_version "${TINY}p1")" vfat/FAT32
expect_eq "TINY passes the boot-sector rules" "$(bootsector_report "${TINY}p1" | tail -1)" "RESULT ok"
# FAT metadata is the only non-zero data after a full format: everything from 20 MiB on must be zero
tail_nonzero=$(sudo dd if="$TINY" bs=1M skip=20 2>/dev/null | tr -d '\0' | wc -c)
echo "non-zero bytes before: $before_nonzero ; non-zero bytes after offset 20 MiB: $tail_nonzero"
expect_eq "no leftover junk after offset 20 MiB" "$tail_nonzero" 0

# ------------------------------------------------------------------------------
section "9. Fallback to parted when sfdisk is not installed"
sudo mv /usr/sbin/sfdisk /usr/sbin/sfdisk.hidden
check "sfdisk is hidden" test ! -e /usr/sbin/sfdisk
out="$(tool_on 'ERASE\n' "$USB3" --label parted 2>&1)"; rc=$?
sudo mv /usr/sbin/sfdisk.hidden /usr/sbin/sfdisk
expect_eq "exit code" "$rc" 0
expect_eq "USB3 is FAT32 (partitioned with parted)" "$(fs_type "${USB3}p1")/$(fat_version "${USB3}p1")" vfat/FAT32
expect_eq "partition type is 0c" "$(sudo sfdisk -d "$USB3" | grep -o 'type=[0-9a-fA-F]*' | head -1)" "type=c"
expect_eq "parted: single partition starting at 1MiB" "$(sudo parted -s "$USB3" unit s print | awk '$1 == 1 { print $2 }')" 2048s
expect_eq "USB3 passes the boot-sector rules" "$(bootsector_report "${USB3}p1" | tail -1)" "RESULT ok"

# ------------------------------------------------------------------------------
section "10. Missing dosfstools gives a clear message and changes nothing"
snap="$(sudo blkid -p -o export "${USB3}p1" | sort | tr '\n' ' ')"
sudo mv /usr/sbin/mkfs.vfat /usr/sbin/mkfs.vfat.hidden
sudo mv /usr/sbin/mkfs.fat /usr/sbin/mkfs.fat.hidden 2>/dev/null
out="$(tool_on 'ERASE\n' "$USB3" 2>&1)"; rc=$?
sudo mv /usr/sbin/mkfs.vfat.hidden /usr/sbin/mkfs.vfat
sudo mv /usr/sbin/mkfs.fat.hidden /usr/sbin/mkfs.fat 2>/dev/null
echo "$out"
expect_eq "exit code" "$rc" 1
expect_contains "names the missing package" "$out" "dosfstools"
expect_eq "drive unchanged" "$(sudo blkid -p -o export "${USB3}p1" | sort | tr '\n' ' ')" "$snap"

# ------------------------------------------------------------------------------
section "11. Run without sudo: the script asks sudo itself"
out="$(printf 'ERASE\n' | bash "$TOOL" --device "$USB1" --allow-non-usb --label viasudo 2>&1)"; rc=$?
echo "$out" | head -3
expect_eq "exit code" "$rc" 0
expect_contains "announces the sudo hand-over" "$out" "asking sudo"
expect_eq "USB1 relabelled by the elevated run" "$(fs_label "${USB1}p1")" VIASUDO

# ------------------------------------------------------------------------------
section "12. Scan mode with the menu (test shim makes the loop drives look like USB sticks)"
cat > "$WORK/fakebin/lsblk" <<'SHIM'
#!/usr/bin/env bash
# Test shim: report the loop devices in $FAKE_USB as whole USB disks, only for the
# machine-readable "-P ... TRAN" query the tool uses to describe a drive.
real=/usr/bin/lsblk
case "$*" in
  *-P*TRAN*)
    "$real" "$@" | while IFS= read -r line; do
      for d in $FAKE_USB; do
        case "$line" in
          NAME=\""$d"\"*)
            line="${line/TYPE=\"loop\"/TYPE=\"disk\"}"
            line="${line/TRAN=\"\"/TRAN=\"usb\"}"
            line="${line/MODEL=\"\"/MODEL=\"Test USB Stick\"}"
            line="${line/VENDOR=\"\"/VENDOR=\"ACME\"}" ;;
        esac
      done
      printf '%s\n' "$line"
    done ;;
  *) exec "$real" "$@" ;;
esac
SHIM
chmod +x "$WORK/fakebin/lsblk"
scan() { # scan "<stdin>" [args]
  local input="$1"; shift
  printf '%b' "$input" | sudo env PATH="$WORK/fakebin:$PATH" FAKE_USB="$USB1 $USB2" bash "$TOOL" "$@"
}
only_test_loop "$USB1"; only_test_loop "$USB2"

out="$(scan 'q\n' --dry-run 2>&1)"; rc=$?
echo "$out"
expect_contains "scan lists USB1" "$out" "$USB1"
expect_contains "scan lists USB2" "$out" "$USB2"
expect_contains "scan shows the drive name" "$out" "ACME Test USB Stick"
expect_lacks "scan never lists the 100 MB drive" "$out" "$TINY "
expect_lacks "scan never lists the 64 GiB drive" "$out" "$HUGE "
expect_lacks "scan never lists the system disk" "$out" "$root_disk"
expect_lacks "scan does not list USB3 (not marked as USB by the shim)" "$out" "$USB3 "

out="$(scan 'q\n' 2>&1)"; rc=$?
expect_eq "quit at the first prompt: exit code" "$rc" 0
expect_eq "quit changes nothing" "$(fs_label "${USB1}p1")" VIASUDO

echo "--- menu walk: abc, 9, 0, '1,2', cancel with 'nope', then ALL + ERASE, then q ---"
out="$(scan 'abc\n9\n0\n1,2\nnope\nALL\nERASE\nq\n' --label walk 2>&1)"; rc=$?
echo "$out" | sed -n '/Please enter/p;/Cancelled/p;/Summary/,$p'
expect_contains "invalid input is rejected politely" "$out" 'Please enter numbers between 1 and 2'
expect_contains "wrong confirmation cancels and re-lists" "$out" "Cancelled. Nothing was changed."
expect_eq "exit code" "$rc" 0
expect_eq "USB1 formatted via ALL" "$(fs_label "${USB1}p1")" WALK
expect_eq "USB2 formatted via ALL" "$(fs_label "${USB2}p1")" WALK

out="$(scan '2\nERASE\nq\n' --label only2 2>&1)"
expect_eq "selecting only drive 2: USB2 formatted" "$(fs_label "${USB2}p1")" ONLY2
expect_eq "selecting only drive 2: USB1 untouched" "$(fs_label "${USB1}p1")" WALK

expect_contains "no-drive case is handled" "$(sudo env PATH="$WORK/fakebin:$PATH" FAKE_USB="" bash "$TOOL" --dry-run 2>&1)" "No USB flash drives of 25-35 GB were found"
out="$(printf '\nq\n' | sudo env PATH="$WORK/fakebin:$PATH" FAKE_USB="" bash "$TOOL" 2>&1)"; rc=$?
expect_eq "no drives: Enter rescans, q quits cleanly (exit code)" "$rc" 0
expect_eq "no drives: asked to plug in a drive twice" "$(printf '%s' "$out" | grep -o 'Plug a drive in' | wc -l | tr -d ' ')" 2

# ------------------------------------------------------------------------------
printf '\n=== RESULT: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
