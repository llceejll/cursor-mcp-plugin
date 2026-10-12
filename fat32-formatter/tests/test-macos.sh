#!/usr/bin/env bash
# Logic test of macos/format-fat32.sh with a SIMULATED diskutil (there is no Mac here).
#
# The stub diskutil prints output in the same shape as real macOS (modern "Disk Size",
# older "Total Size", APFS "Part of Whole" / "APFS Physical Store") and records every
# destructive call. What this proves: drive selection and refusals, the confirmation flow,
# the exact diskutil commands issued, failure handling, and bash 3.2 compatibility when
# run with the real bash 3.2.57 that macOS ships. It cannot prove how diskutil behaves on a
# real Mac.
#
#   bash test-macos.sh /path/to/format-fat32.sh /path/to/bash [workdir]
set -u
TOOL="$(readlink -f "${1:?usage: test-macos.sh format-fat32.sh bash [workdir]}")"
BASH_BIN="${2:?bash to run the tool with}"
WORK="${3:-/tmp/fat32-dev/work-mac}"
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/state"
WORK="$(readlink -f "$WORK")"
STATE="$WORK/state"

PASS=0
FAIL=0
section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1 (= $3)"; else bad "$1: got '$2', wanted '$3'"; fi; }
expect_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: output lacked '$3'" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) bad "$1: output unexpectedly had '$3'" ;; *) ok "$1" ;; esac; }

# ------------------------------------------------------------------ stub diskutil / df
cat > "$WORK/bin/diskutil" <<'STUB'
#!/usr/bin/env bash
S="${STUB_DIR:?}"
name_of() { local n="${1#/dev/}"; [ "$n" = "/" ] && n=ROOT; printf '%s' "$n"; }
case "${1:-}" in
  list)
    if [ "${2:-}" = "external" ]; then cat "$S/list-external.txt"; exit 0; fi
    f="$S/list-$(name_of "$2").txt"; [ -f "$f" ] && cat "$f"; exit 0 ;;
  info)
    f="$S/info/$(name_of "$2").txt"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    echo "Could not find disk: $2" >&2; exit 1 ;;
  unmountDisk)
    echo "unmountDisk $*" >> "$S/calls.log"
    [ -f "$S/fail-unmount-$(name_of "${3:-}")" ] && { echo "Unmount failed" >&2; exit 1; }
    exit 0 ;;
  eraseDisk)
    echo "eraseDisk $*" >> "$S/calls.log"
    id="$(name_of "${5:-}")"
    [ -f "$S/fail-erase-$id" ] && { echo "Erase failed" >&2; exit 1; }
    fs="MS-DOS FAT32"; [ -f "$S/erase-gives-exfat-$id" ] && fs="ExFAT"
    cat > "$S/info/${id}s1.txt" <<EOF
   Device Identifier:         ${id}s1
   Part of Whole:             ${id}
   Volume Name:               ${3:-}
   File System Personality:   ${fs}
   Type (Bundle):             msdos
EOF
    exit 0 ;;
esac
exit 0
STUB
cat > "$WORK/bin/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem   512-blocks      Used Available Capacity  Mounted on\n'
printf '%s  100 50 50 50%% /Volumes/whatever\n' "$(cat "${STUB_DIR:?}/df-source")"
STUB
chmod +x "$WORK/bin/diskutil" "$WORK/bin/df"

info_disk() { # info_disk ID "Media name" BYTES PROTOCOL [LOCATION] [SIZEKEY]
  local id="$1" name="$2" bytes="$3" proto="$4" loc="${5:-External}" key="${6:-Disk Size}"
  mkdir -p "$STATE/info"
  cat > "$STATE/info/$id.txt" <<EOF
   Device Identifier:         $id
   Device Node:               /dev/$id
   Whole:                     Yes
   Part of Whole:             $id
   Device / Media Name:       $name

   Volume Name:               Not applicable (no file system)
   Mounted:                   Not applicable (no file system)
   File System:               None

   Content (IOContent):       FDisk_partition_scheme
   OS Can Be Installed:       No
   Media Type:                Generic
   Protocol:                  $proto
   SMART Status:              Not Supported

   $key:$(printf '%*s' $((26 - ${#key} - 1)) '')$(awk -v b="$bytes" 'BEGIN { printf "%.1f GB", b/1e9 }') ($bytes Bytes) (exactly $((bytes / 512)) 512-Byte-Units)
   Device Block Size:         512 Bytes

   Read-Only Media:           No

   Device Location:           $loc
   Removable Media:           Removable
   Media Removal:             Software-Activated
EOF
  printf '%s\n' "/dev/$id (external, physical):" >> "$STATE/list-external.txt"
  printf '   #:                       TYPE NAME                    SIZE       IDENTIFIER\n   0:     FDisk_partition_scheme                        *%s    %s\n' "$(awk -v b="$bytes" 'BEGIN { printf "%.1f GB", b/1e9 }')" "$id" >> "$STATE/list-external.txt"
  printf '%s\n' "/dev/$id (external, physical):" "   #:                       TYPE NAME                    SIZE       IDENTIFIER" "   0:     FDisk_partition_scheme                        *$(awk -v b="$bytes" 'BEGIN { printf "%.1f GB", b/1e9 }')    $id" > "$STATE/list-$id.txt"
}

build_world() {
  rm -rf "$STATE"; mkdir -p "$STATE/info"
  : > "$STATE/list-external.txt"
  : > "$STATE/calls.log"
  info_disk disk4 "SanDisk Ultra" 32015679488 USB
  info_disk disk5 "Cheap 16GB" 15376000000 USB
  info_disk disk6 "Lexar 64GB" 63864569856 USB
  info_disk disk7 "Samsung Portable SSD" 30000000000 "PCI-Express"
  info_disk disk8 "Boot stick" 31000000000 USB
  info_disk disk9 "Toolkit stick" 31000000000 USB
  info_disk disk10 "Old Kingston" 30765219840 USB External "Total Size"
  info_disk disk11 "Internal-looking" 31000000000 USB Internal
  # The running system: APFS volume in a container whose physical store is on disk8 (booted from USB)
  cat > "$STATE/info/ROOT.txt" <<'EOF'
   Device Identifier:         disk3s1s1
   Part of Whole:             disk3
   APFS Physical Store:       disk8s2
   Mount Point:               /
EOF
  # The script runs from a volume on disk9
  printf '/dev/disk9s1' > "$STATE/df-source"
  cat > "$STATE/info/disk9s1.txt" <<'EOF'
   Device Identifier:         disk9s1
   Part of Whole:             disk9
EOF
}

run_tool() { # run_tool "<stdin>" [args...]  (as root, stub tools first in PATH)
  local input="$1"; shift
  printf '%b' "$input" | sudo env PATH="$WORK/bin:$PATH" STUB_DIR="$STATE" "$BASH_BIN" "$TOOL" "$@"
}
calls() { cat "$STATE/calls.log"; }

echo "bash running the tool : $("$BASH_BIN" --version | head -1)"
"$BASH_BIN" -n "$TOOL" && ok "syntax check with this bash"

# ------------------------------------------------------------------------------
section "1. Dry run: which drives are offered"
build_world
out="$(sudo env PATH="$WORK/bin:$PATH" STUB_DIR="$STATE" "$BASH_BIN" "$TOOL" --dry-run 2>&1)"; rc=$?
echo "$out"
expect_eq "exit code" "$rc" 0
expect_contains "disk4 (USB, 32 GB, 'Disk Size' format) offered" "$out" "/dev/disk4"
expect_contains "disk10 (USB, 30.8 GB, older 'Total Size' format) offered" "$out" "/dev/disk10"
expect_lacks "16 GB stick not offered as a candidate" "$(printf '%s\n' "$out" | sed -n '/No\. /,/^$/p')" "disk5"
expect_contains "16 GB stick explained" "$out" "disk5  Cheap 16GB  - size 15.4 GB (14.3 GiB) is outside 25-35 GB"
expect_contains "64 GB stick explained" "$out" "disk6  Lexar 64GB  - size 63.9 GB (59.5 GiB) is outside 25-35 GB"
expect_contains "PCIe SSD refused (not USB)" "$out" "disk7  Samsung Portable SSD  - not a USB drive (protocol: PCI-Express)"
expect_contains "the USB stick macOS booted from is refused" "$out" "disk8  Boot stick  - it holds macOS or this tool"
expect_contains "the USB stick the tool runs from is refused" "$out" "disk9  Toolkit stick  - it holds macOS or this tool"
expect_contains "a disk that is not external is refused" "$out" "disk11  Internal-looking  - not an external drive"
expect_eq "dry run issued no diskutil erase/unmount" "$(calls | wc -l | tr -d ' ')" 0

# ------------------------------------------------------------------------------
section "2. Normal run: pick 1,2 and type ERASE"
build_world
out="$(run_tool '1,2\nERASE\nq\n' 2>&1)"; rc=$?
echo "$out" | sed -n '/ERASED/,$p'
expect_eq "exit code" "$rc" 0
expect_eq "exact diskutil commands, in order" "$(calls | tr '\n' '|')" "unmountDisk unmountDisk force /dev/disk4|eraseDisk eraseDisk FAT32 USB32 MBRFormat /dev/disk4|unmountDisk unmountDisk force /dev/disk10|eraseDisk eraseDisk FAT32 USB32 MBRFormat /dev/disk10|"
expect_contains "summary lists both as OK" "$out" "OK      /dev/disk10  ->  /dev/disk10s1  FAT32  USB32"
expect_lacks "refused disks were never touched" "$(calls)" "disk8"
expect_lacks "refused disks were never touched (2)" "$(calls)" "disk9"

section "3. Label, wrong confirmation, invalid input, quit"
build_world
out="$(run_tool 'x\n9\n0\n1\nerase\n2\nERASE\nq\n' --label "my usb" 2>&1)"; rc=$?
echo "$out" | sed -n '/Please enter/p;/Cancelled/p;/Summary/,$p'
expect_eq "exit code" "$rc" 0
expect_contains "invalid input rejected" "$out" 'Please enter numbers between 1 and 2'
expect_contains "lower-case erase cancels" "$out" "Cancelled. Nothing was changed."
expect_eq "only the 2nd selection was erased, label upper-cased" "$(calls | tr '\n' '|')" "unmountDisk unmountDisk force /dev/disk10|eraseDisk eraseDisk FAT32 MY USB MBRFormat /dev/disk10|"
build_world; out="$(run_tool 'q\n' 2>&1)"; expect_eq "q at the menu changes nothing" "$(calls | wc -l | tr -d ' ')" 0
build_world; out="$(run_tool 'ALL\n\n' 2>&1)"; expect_eq "closed input at the confirmation changes nothing" "$(calls | wc -l | tr -d ' ')" 0
build_world; out="$(run_tool '1\n' 2>&1)"; expect_eq "input ending before the confirmation changes nothing" "$(calls | wc -l | tr -d ' ')" 0
build_world; out="$(run_tool 'all\nERASE\n\n' 2>&1)"; expect_eq "'all' formats both candidates" "$(calls | grep -c '^eraseDisk')" 2

section "4. Guard against a drive that changed between the list and the erase"
build_world
out="$(sudo env PATH="$WORK/bin:$PATH" STUB_DIR="$STATE" "$BASH_BIN" -c "
  source '$TOOL'
  PROTECTED=\"\$(protected_disks | sort -u)\"
  check_disk disk4 || { echo \"check_disk failed: \$REASON\"; exit 3; }
  good_size=\$D_SIZE; good_name=\$D_NAME
  format_one disk4 \$((good_size + 512)) \"\$good_name\"; echo \"wrong size -> \${RES_LINE[0]:-?}\"
  format_one disk4 \"\$good_size\" 'Some Other Stick'; echo \"wrong name -> \${RES_LINE[1]:-?}\"
" 2>&1)"
echo "$out"
expect_contains "size mismatch refused" "$out" "wrong size -> /dev/disk4  FAILED: skipped - the drive changed since it was listed"
expect_contains "name mismatch refused" "$out" "wrong name -> /dev/disk4  FAILED: skipped - the drive changed since it was listed"
expect_eq "no destructive command was issued" "$(calls | wc -l | tr -d ' ')" 0

section "5. Failures"
build_world; : > "$STATE/fail-unmount-disk4"
out="$(run_tool '1,2\nERASE\nq\n' 2>&1)"; rc=$?
echo "$out" | sed -n '/Summary/,$p'
expect_eq "unmount failure: exit code" "$rc" 1
expect_contains "unmount failure reported" "$out" "FAILED  /dev/disk4  FAILED: could not unmount it"
expect_eq "unmount failure: disk4 never erased, disk10 still done" "$(calls | grep '^eraseDisk' | tr '\n' '|')" "eraseDisk eraseDisk FAT32 USB32 MBRFormat /dev/disk10|"
build_world; : > "$STATE/fail-erase-disk4"
out="$(run_tool '1\nERASE\nq\n' 2>&1)"; rc=$?
expect_eq "erase failure: exit code" "$rc" 1
expect_contains "erase failure reported" "$out" "diskutil eraseDisk failed"
build_world; : > "$STATE/erase-gives-exfat-disk4"
out="$(run_tool '1\nERASE\nq\n' 2>&1)"; rc=$?
expect_eq "verification failure (not FAT32): exit code" "$rc" 1
expect_contains "verification failure reported" "$out" "macOS does not report FAT32 for /dev/disk4s1"

section "6. Nothing plugged in, and option checks"
build_world; : > "$STATE/list-external.txt"
out="$(run_tool '\nq\n' 2>&1)"; rc=$?
expect_eq "no drives: exit code" "$rc" 0
expect_eq "no drives: asked to plug in twice" "$(printf '%s' "$out" | grep -o 'Plug a drive in' | wc -l | tr -d ' ')" 2
out="$("$BASH_BIN" "$TOOL" --label 'bad/label' --dry-run 2>&1)"; expect_eq "bad label: exit code" "$?" 2
out="$("$BASH_BIN" "$TOOL" --min-gb 40 --max-gb 30 --dry-run 2>&1)"; expect_eq "min > max: exit code" "$?" 2
out="$("$BASH_BIN" "$TOOL" --min-gb x --dry-run 2>&1)"; expect_eq "non-number: exit code" "$?" 2
out="$("$BASH_BIN" "$TOOL" --nope 2>&1)"; expect_eq "unknown option: exit code" "$?" 2
out="$("$BASH_BIN" "$TOOL" --help 2>&1)"; expect_contains "help text" "$out" "FAT32 flash drive formatter"
out="$(PATH="/usr/bin:/bin" "$BASH_BIN" "$TOOL" --dry-run 2>&1)"; rc=$?
expect_contains "no diskutil (not a Mac): clear message" "$out" "diskutil was not found"

printf '\n=== RESULT: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
