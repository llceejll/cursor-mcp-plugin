#!/usr/bin/env bash
# Final evidence run: unpack the SHIPPED package and run every suite against it, writing
# one log per suite.
#
#   bash run-evidence.sh OUT_DIR LOG_DIR
set -u
OUT="$(readlink -f "${1:?usage: run-evidence.sh OUT_DIR LOG_DIR}")"
LOGS="${2:?log directory}"
mkdir -p "$LOGS"; LOGS="$(readlink -f "$LOGS")"
DEV="$(readlink -f "$(dirname "$(readlink -f "$0")")/..")"
# Override with PWSH=/path/to/pwsh and BASH32=/path/to/bash-3.2 (a bash 3.2 build, the version macOS ships).
PWSH="${PWSH:-$DEV/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH="$(command -v pwsh || true)"
BASH32="${BASH32:-$DEV/bash32/install/bin/bash}"
[ -x "$BASH32" ] || BASH32=""
[ -n "$PWSH" ] || { echo "PowerShell 7 (pwsh) is needed: set PWSH=/path/to/pwsh" >&2; exit 2; }
T="$(mktemp -d /tmp/fat32-evidence.XXXXXX)"
trap 'rm -rf "$T"' EXIT

ZIP="$OUT/FAT32-Formatter-Offline-Package-ready-to-run.zip"
mkdir -p "$T/pkg" && (cd "$T/pkg" && unzip -q "$ZIP") || exit 1
RTR="$T/pkg/FAT32-Formatter"
header() { printf 'Package under test : %s\nsha256             : %s\nDate               : %s\n\n' "$(basename "$ZIP")" "$(sha256sum "$ZIP" | cut -d' ' -f1)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
rc=0

{ header; echo "Linux script: $RTR/linux/format-fat32.sh"; bash "$DEV/tests/test-linux.sh" "$RTR/linux/format-fat32.sh" "$T/linuxwork"; } > "$LOGS/1-linux-real-block-devices.log" 2>&1 || rc=1
{ header; "$PWSH" -NoLogo -NoProfile -File "$DEV/tests/windows-mock-tests.ps1" -ScriptPath "$RTR/windows/Format-Fat32.ps1"; } > "$LOGS/2-windows-mocked-storage-cmdlets.log" 2>&1 || rc=1
{
  header
  "$PWSH" -NoLogo -NoProfile -File "$DEV/tests/parse.ps1" -Files "$RTR/windows/Format-Fat32.ps1"
  for m in general syntax commands; do
    case "$m" in
      general) title="general PSScriptAnalyzer rules (errors, warnings, information)" ;;
      syntax) title="syntax compatible with Windows PowerShell 5.1" ;;
      commands) title="every cmdlet and parameter exists in Windows 10 1809 / Server 2016 / Server 2019 PowerShell 5.1" ;;
    esac
    echo; echo "--- $title ---"
    "$PWSH" -NoLogo -NoProfile -File "$DEV/tests/analyze.ps1" -Script "$RTR/windows/Format-Fat32.ps1" -Mode "$m"
  done
} > "$LOGS/3-windows-static-analysis.log" 2>&1 || rc=1
if [ -n "$BASH32" ]; then
  { header; bash "$DEV/tests/test-macos.sh" "$RTR/macos/format-fat32.sh" "$BASH32" "$T/macwork32"; } > "$LOGS/4-macos-simulated-diskutil-bash-3.2.log" 2>&1 || rc=1
else
  { header; echo "SKIPPED: no bash 3.2 build found. Set BASH32=/path/to/bash-3.2 to run the macOS suite on the shell macOS ships."; } > "$LOGS/4-macos-simulated-diskutil-bash-3.2.log"
fi
{ header; bash "$DEV/tests/test-macos.sh" "$RTR/macos/format-fat32.sh" "$(command -v bash)" "$T/macwork5"; } > "$LOGS/4b-macos-simulated-diskutil-bash-5.log" 2>&1 || rc=1
{ header; bash "$DEV/tests/verify-package.sh" "$OUT"; } > "$LOGS/5-package-as-the-recipient-sees-it.log" 2>&1 || rc=1
{ header; python3 "$DEV/tests/validate_eml.py" "$OUT/Email-Draft-to-Wheelzy.eml" "$OUT/FAT32-Formatter-Offline-Package.zip"; } > "$LOGS/6-email-draft-validation.log" 2>&1 || rc=1

for f in "$LOGS"/*.log; do printf '%-62s %s\n' "$(basename "$f")" "$(grep -E '^(=== RESULT|=== PACKAGE VERIFICATION|ALL CHECKS PASSED|no findings)' "$f" | tail -1)"; done
exit "$rc"
