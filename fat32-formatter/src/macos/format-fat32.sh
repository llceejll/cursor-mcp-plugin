#!/bin/bash
#
# format-fat32.sh - format 32 GB USB flash drives as FAT32 on macOS. Works offline.
#
#   sudo bash format-fat32.sh          scan for drives, choose, confirm, format
#   bash format-fat32.sh --dry-run     only show which drives would be offered
#   bash format-fat32.sh --help        all options
#
# Safety rules built in:
#   - only external USB drives between --min-gb and --max-gb are offered
#   - the drive that holds macOS, and the drive this script is running from,
#     are never offered
#   - nothing changes until you type ERASE
#   - every drive is checked again right before it is erased
#
# Uses only tools that ship with macOS (diskutil, awk, sed). No internet
# connection is used. Written for the bash 3.2 that macOS includes.

set -u

VERSION="1.0.0"
VOL_LABEL="USB32"
MIN_GB="25"
MAX_GB="35"
DRY_RUN=0
ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

CAND_ID=()
CAND_SIZE=()
CAND_NAME=()
SKIPPED=()
SELECTION=()
RES_OK=()
RES_LINE=()
PROTECTED=""
REASON=""
VERIFY_MSG=""
D_SIZE=""
D_NAME=""
ANY_FAIL=0

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'ERROR: %s\nTry: bash %s --help\n' "$*" "$0" >&2; exit 2; }

usage() {
  cat <<EOF
FAT32 flash drive formatter v$VERSION (macOS, offline)

Usage: sudo bash format-fat32.sh [options]

  -l, --label NAME    Name for the new volume: 1-11 letters, digits, space, - or _
                      (default: USB32)
      --min-gb N      Smallest drive to offer, in decimal GB (default: 25)
      --max-gb N      Largest drive to offer, in decimal GB (default: 35)
      --dry-run       Only show which drives would be offered; change nothing
  -h, --help          Show this help
      --version       Show the version

Everything on a drive you choose is erased and cannot be recovered.
EOF
}

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--label)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      VOL_LABEL="$2"; shift 2 ;;
    --label=*) VOL_LABEL="${1#*=}"; shift ;;
    --min-gb)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      MIN_GB="$2"; shift 2 ;;
    --min-gb=*) MIN_GB="${1#*=}"; shift ;;
    --max-gb)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      MAX_GB="$2"; shift 2 ;;
    --max-gb=*) MAX_GB="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) say "$VERSION"; exit 0 ;;
    *) usage_error "Unknown option: $1" ;;
  esac
done

is_number() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
to_bytes() { awk -v g="$1" 'BEGIN { printf "%.0f", g * 1e9 }'; }
size_text() { awk -v b="$1" 'BEGIN { printf "%.1f GB (%.1f GiB)", b / 1e9, b / 1073741824 }'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

label_re='^[A-Za-z0-9 _-]{1,11}$'
[[ $VOL_LABEL =~ $label_re ]] || usage_error "The label must be 1-11 letters, digits, spaces, - or _"
VOL_LABEL="$(printf '%s' "$VOL_LABEL" | tr '[:lower:]' '[:upper:]')"
if ! { is_number "$MIN_GB" && is_number "$MAX_GB"; }; then usage_error "--min-gb and --max-gb must be numbers"; fi
MIN_BYTES="$(to_bytes "$MIN_GB")"
MAX_BYTES="$(to_bytes "$MAX_GB")"
if ! { [ "$MIN_BYTES" -gt 0 ] && [ "$MAX_BYTES" -gt "$MIN_BYTES" ]; }; then usage_error "--max-gb must be larger than --min-gb"; fi

# ---------------------------------------------------------- root and tools
if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "Administrator rights are needed. Run this with: sudo bash $0"
  say "Administrator rights are needed - asking sudo (you may be asked for your password)."
  exec sudo bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

command -v diskutil >/dev/null 2>&1 || die "diskutil was not found. This script is for macOS; use the Linux or Windows version elsewhere."

# ------------------------------------------------------------ drive checks
# disk_field DEVICE "Field name": the value of one line of `diskutil info`
disk_field() {
  diskutil info "$1" 2>/dev/null | awk -F: -v key="$2" '
    { k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k) }
    k == key { v = $0; sub(/^[^:]*:[ \t]*/, "", v); print v; exit }'
}

disk_bytes() {
  local key v
  for key in "Disk Size" "Total Size"; do
    v="$(disk_field "$1" "$key")"
    if [ -n "$v" ]; then
      printf '%s\n' "$v" | sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p'
      return 0
    fi
  done
  return 0
}

# The whole disk(s) that physically hold a device or mounted volume. APFS volumes
# live in a synthesized container, so the physical store is listed too.
whole_disks_of() {
  diskutil info "$1" 2>/dev/null | awk -F: '
    { k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k); v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v) }
    k == "Part of Whole" || k == "APFS Physical Store" { print v }' \
    | sed -n 's/^\(disk[0-9][0-9]*\).*/\1/p'
}

protected_disks() {
  local src
  whole_disks_of /
  if [ -n "$SCRIPT_DIR" ]; then
    src="$(df -P "$SCRIPT_DIR" 2>/dev/null | awk 'NR == 2 { print $1 }')"
    if [ -n "$src" ]; then whole_disks_of "$src"; fi
  fi
  return 0
}

# check_disk diskN: returns 0 if the drive may be formatted. Otherwise returns 1
# and REASON says why. Needs PROTECTED to be filled in first.
check_disk() {
  local id="$1" location protocol
  REASON=""; D_SIZE=""; D_NAME=""
  location="$(disk_field "/dev/$id" "Device Location")"
  protocol="$(disk_field "/dev/$id" "Protocol")"
  D_SIZE="$(disk_bytes "/dev/$id")"
  D_NAME="$(disk_field "/dev/$id" "Device / Media Name")"
  [ -n "$D_NAME" ] || D_NAME="(unnamed drive)"
  if [ "$location" != "External" ]; then
    REASON="not an external drive"
    return 1
  fi
  case "$protocol" in
    *USB*) ;;
    *) REASON="not a USB drive (protocol: ${protocol:-unknown})"; return 1 ;;
  esac
  case "$D_SIZE" in
    ''|*[!0-9]*) REASON="cannot read the drive size"; return 1 ;;
  esac
  if [ "$D_SIZE" -lt "$MIN_BYTES" ] || [ "$D_SIZE" -gt "$MAX_BYTES" ]; then
    REASON="size $(size_text "$D_SIZE") is outside $MIN_GB-$MAX_GB GB"
    return 1
  fi
  if printf '%s\n' "$PROTECTED" | grep -qx "$id"; then
    REASON="it holds macOS or this tool"
    return 1
  fi
  return 0
}

scan_disks() {
  local id ids
  CAND_ID=(); CAND_SIZE=(); CAND_NAME=(); SKIPPED=()
  PROTECTED="$(protected_disks | sort -u)"
  ids="$(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ / { sub("/dev/", "", $1); print $1 }')"
  for id in $ids; do
    if check_disk "$id"; then
      CAND_ID+=("$id")
      CAND_SIZE+=("$D_SIZE")
      CAND_NAME+=("$D_NAME")
    else
      SKIPPED+=("/dev/$id  $D_NAME  - $REASON")
    fi
  done
}

# ----------------------------------------------------------------- display
show_candidates() {
  local i
  say ""
  printf '  %-4s %-12s %-24s %s\n' "No." "Device" "Size" "Drive"
  for ((i = 0; i < ${#CAND_ID[@]}; i++)); do
    printf '  %-4s %-12s %-24s %s\n' "$((i + 1))" "/dev/${CAND_ID[$i]}" "$(size_text "${CAND_SIZE[$i]}")" "${CAND_NAME[$i]}"
    diskutil list "/dev/${CAND_ID[$i]}" 2>/dev/null | sed -n '3,$p' | sed 's/^/        /'
  done
  say ""
}

show_skipped() {
  local i
  if [ "${#SKIPPED[@]}" -eq 0 ]; then return 0; fi
  say "External drives that were ignored:"
  for ((i = 0; i < ${#SKIPPED[@]}; i++)); do say "  ${SKIPPED[$i]}"; done
}

# --------------------------------------------------------------- prompts
read_selection() {
  local count="$1" answer ok tok n sorted
  local toks=()
  while true; do
    printf 'Type the number(s) of the drive(s) to ERASE (example: 1 or 1,2), "all", or q to quit: '
    IFS= read -r answer || { echo; return 1; }
    answer="$(trim "$answer")"
    case "$(lower "$answer")" in
      q|quit|exit) return 1 ;;
      all)
        SELECTION=()
        for ((n = 1; n <= count; n++)); do SELECTION+=("$n"); done
        return 0 ;;
    esac
    ok=1
    SELECTION=()
    toks=()
    IFS=' ' read -r -a toks <<< "${answer//,/ }"
    for ((n = 0; n < ${#toks[@]}; n++)); do
      tok="${toks[$n]}"
      case "$tok" in
        ''|*[!0-9]*) ok=0 ;;
        *) if [ "$tok" -ge 1 ] && [ "$tok" -le "$count" ]; then SELECTION+=("$tok"); else ok=0; fi ;;
      esac
    done
    if [ "$ok" -eq 1 ] && [ "${#SELECTION[@]}" -gt 0 ]; then
      sorted="$(printf '%s\n' "${SELECTION[@]}" | sort -nu)"
      SELECTION=()
      for tok in $sorted; do SELECTION+=("$tok"); done
      return 0
    fi
    say "Please enter numbers between 1 and $count, \"all\", or q."
  done
}

confirm_erase() {
  local k idx answer
  say ""
  say "These drives will be ERASED. Everything on them will be lost for good:"
  for ((k = 0; k < ${#SELECTION[@]}; k++)); do
    idx=$((SELECTION[k] - 1))
    say "  ${SELECTION[$k]}) /dev/${CAND_ID[$idx]}  $(size_text "${CAND_SIZE[$idx]}")  ${CAND_NAME[$idx]}"
  done
  printf 'Type ERASE (all capitals) to continue, anything else cancels: '
  IFS= read -r answer || answer=""
  [ "$(trim "$answer")" = "ERASE" ]
}

# ------------------------------------------------------------- formatting
record_ok() { RES_OK+=(1); RES_LINE+=("$1  ->  $2  FAT32  $VOL_LABEL"); }
record_fail() { RES_OK+=(0); RES_LINE+=("$1  FAILED: $2"); ANY_FAIL=1; }

verify_result() {
  local info name
  VERIFY_MSG=""
  info="$(diskutil info "$1" 2>/dev/null)"
  if ! printf '%s\n' "$info" | grep -q 'FAT32'; then
    VERIFY_MSG="macOS does not report FAT32 for $1"
    return 1
  fi
  name="$(disk_field "$1" "Volume Name")"
  if [ "$name" != "$VOL_LABEL" ]; then
    VERIFY_MSG="the volume name is '$name', expected '$VOL_LABEL'"
    return 1
  fi
  return 0
}

format_one() {
  local id="$1" want_size="$2" want_name="$3" part

  say ""
  say "[/dev/$id] checking..."
  PROTECTED="$(protected_disks | sort -u)"
  if ! check_disk "$id"; then
    record_fail "/dev/$id" "skipped - $REASON"
    return 1
  fi
  if [ "$D_SIZE" != "$want_size" ] || [ "$D_NAME" != "$want_name" ]; then
    record_fail "/dev/$id" "skipped - the drive changed since it was listed"
    return 1
  fi

  say "[/dev/$id] unmounting..."
  if ! diskutil unmountDisk force "/dev/$id" >/dev/null 2>&1; then
    record_fail "/dev/$id" "could not unmount it - close programs that use the drive and try again"
    return 1
  fi

  say "[/dev/$id] erasing and formatting as FAT32 (label $VOL_LABEL)..."
  if ! diskutil eraseDisk FAT32 "$VOL_LABEL" MBRFormat "/dev/$id" >/dev/null 2>&1; then
    record_fail "/dev/$id" "diskutil eraseDisk failed"
    return 1
  fi

  say "[/dev/$id] verifying..."
  part="/dev/${id}s1"
  if ! verify_result "$part"; then
    record_fail "/dev/$id" "verification failed: $VERIFY_MSG"
    return 1
  fi
  say "[/dev/$id] done."
  record_ok "/dev/$id" "$part"
}

format_selected() {
  local k idx
  RES_OK=(); RES_LINE=()
  for ((k = 0; k < ${#SELECTION[@]}; k++)); do
    idx=$((SELECTION[k] - 1))
    format_one "${CAND_ID[$idx]}" "${CAND_SIZE[$idx]}" "${CAND_NAME[$idx]}" || true
  done
  say ""
  say "Summary"
  for ((k = 0; k < ${#RES_LINE[@]}; k++)); do
    if [ "${RES_OK[$k]}" -eq 1 ]; then say "  OK      ${RES_LINE[$k]}"; else say "  FAILED  ${RES_LINE[$k]}"; fi
  done
  say ""
}

# --------------------------------------------------------------- main flow
run_scan_loop() {
  local answer
  while true; do
    scan_disks
    if [ "${#CAND_ID[@]}" -eq 0 ]; then
      say ""
      say "No USB flash drives of $MIN_GB-$MAX_GB GB were found."
      show_skipped
      if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
      printf 'Plug a drive in, then press Enter to scan again (or type q to quit): '
      IFS= read -r answer || { echo; return 0; }
      case "$(lower "$(trim "$answer")")" in q|quit|exit) return 0 ;; esac
      continue
    fi
    show_candidates
    show_skipped
    if [ "$DRY_RUN" -eq 1 ]; then
      say "DRY RUN: nothing was changed."
      return 0
    fi
    read_selection "${#CAND_ID[@]}" || return 0
    if ! confirm_erase; then
      say "Cancelled. Nothing was changed."
      continue
    fi
    format_selected
    printf 'Swap in more drives and press Enter to scan again (or type q to quit): '
    IFS= read -r answer || { echo; return 0; }
    case "$(lower "$(trim "$answer")")" in q|quit|exit) return 0 ;; esac
  done
}

main() {
  say ""
  say "FAT32 flash drive formatter v$VERSION  (offline - nothing is downloaded)"
  say "Formats USB drives of $MIN_GB-$MAX_GB GB as one FAT32 volume named $VOL_LABEL."
  run_scan_loop
  exit "$ANY_FAIL"
}

# Run only when executed, not when sourced (the tests source this file).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
