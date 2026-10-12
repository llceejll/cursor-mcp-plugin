#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2024  # test-harness idioms: pass/fail counters, PowerShell snippets in single quotes, redirects that must stay owned by the caller
# Acts like the person who receives the package: unzip, follow the README, then re-run
# every test suite against the files that were actually shipped.
#
#   bash verify-package.sh OUT_DIR   (OUT_DIR holds the two zips built by build_package.py)
set -u
OUT="$(readlink -f "${1:?usage: verify-package.sh OUT_DIR}")"
DEV="$(dirname "$(readlink -f "$0")")/.."
DEV="$(readlink -f "$DEV")"
# Override with PWSH=/path/to/pwsh and BASH32=/path/to/bash-3.2 (a bash 3.2 build, the version macOS ships).
PWSH="${PWSH:-$DEV/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH="$(command -v pwsh || true)"
BASH32="${BASH32:-$DEV/bash32/install/bin/bash}"
[ -x "$BASH32" ] || BASH32=""
[ -n "$PWSH" ] || { echo "PowerShell 7 (pwsh) is needed: set PWSH=/path/to/pwsh" >&2; exit 2; }
T="$(mktemp -d /tmp/fat32-verify.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: output lacked '$3'"; printf '%s\n' "$2" | head -5 ;; esac; }

section "A. The e-mail attachment, as the recipient receives it"
mkdir -p "$T/mail" && cd "$T/mail" && unzip -q "$OUT/FAT32-Formatter-Offline-Package.zip" && cd FAT32-Formatter || exit 1
find . -type f | sort
check "no script file has an extension that mail systems block (.ps1 .cmd .bat .sh .js .vbs .exe)" bash -c '! find . -type f | grep -E "\.(ps1|cmd|bat|sh|js|vbs|exe|msi|scr|com|lnk|jar)$"'
check "sha256sum -c passes BEFORE renaming (as README says)" sha256sum -c SHA256SUMS.txt
echo "--- README's Windows checksum command, run in PowerShell ---"
"$PWSH" -NoLogo -NoProfile -Command '
$sums = @{}; Get-Content ./SHA256SUMS.txt | ForEach-Object { $h, $n = $_ -split "  ", 2; $sums[$n] = $h }
$bad = 0
Get-FileHash -Algorithm SHA256 -Path .\windows\*, .\macos\*, .\linux\* | ForEach-Object {
  $rel = (Resolve-Path -Relative $_.Path) -replace "^\.[\\/]", "" -replace "\\", "/"
  $ok = $sums[$rel] -eq $_.Hash.ToLower()
  "{0}  {1}" -f $(if ($ok) { "match   " } else { "MISMATCH" }), $rel
  if (-not $ok) { $bad++ }
}
exit $bad' && ok "PowerShell Get-FileHash matches SHA256SUMS.txt for every script" || bad "PowerShell Get-FileHash mismatch"

section "B. README STEP 0 - the Windows rename command (PowerShell)"
cp -r "$T/mail/FAT32-Formatter" "$T/win"; cd "$T/win" || exit 1
"$PWSH" -NoLogo -NoProfile -Command "Get-ChildItem -Recurse -Filter '*.txt' | Where-Object { \$_.Name -match '\.(ps1|cmd|sh)\.txt\$' } | Rename-Item -NewName { \$_.Name -replace '\.txt\$','' }"
find . -type f | sort
for f in windows/Format-Fat32.cmd windows/Format-Fat32.ps1 macos/format-fat32.sh linux/format-fat32.sh README.txt SHA256SUMS.txt; do check "exists after rename: $f" test -f "$f"; done

section "C. README STEP 0 - the Mac/Linux rename command"
cp -r "$T/mail/FAT32-Formatter" "$T/nix"; cd "$T/nix" || exit 1
bash -c 'for f in */*.sh.txt; do mv "$f" "${f%.txt}"; done'
for f in macos/format-fat32.sh linux/format-fat32.sh; do check "exists after rename: $f" test -f "$f"; done
check "README.txt and the Windows files were left alone by that command" bash -c 'test -f README.txt && test -f windows/Format-Fat32.ps1.txt && test -f windows/Format-Fat32.cmd.txt'

section "D. The ready-to-run zip"
mkdir -p "$T/rtr" && cd "$T/rtr" && unzip -q "$OUT/FAT32-Formatter-Offline-Package-ready-to-run.zip" && cd FAT32-Formatter || exit 1
check "sha256sum -c passes" sha256sum -c SHA256SUMS.txt
check "Linux and Mac scripts are executable straight from the zip" bash -c 'test -x linux/format-fat32.sh && test -x macos/format-fat32.sh'
RTR="$T/rtr/FAT32-Formatter"
check "Windows launcher: every line ends in CRLF (no bare LF)" python3 -c "
d = open('windows/Format-Fat32.cmd','rb').read()
assert d.count(b'\r\n') == d.count(b'\n') > 5, (d.count(b'\r\n'), d.count(b'\n'))"
check "launcher mentions both files it needs" bash -c "grep -q 'Format-Fat32.ps1' windows/Format-Fat32.cmd && grep -q 'ExecutionPolicy Bypass' windows/Format-Fat32.cmd"

section "E. No-rename Windows route: run the .ps1.txt text directly (README one-liner, PowerShell)"
cd "$T/mail/FAT32-Formatter/windows" || exit 1
out="$("$PWSH" -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '.\\Format-Fat32.ps1.txt'))) -Label 'bad/label' -DryRun" 2>&1)"
expect_contains "scriptblock route runs and validates the label" "$out" "The label must be 1-11 letters"
out="$("$PWSH" -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '.\\Format-Fat32.ps1.txt'))) -DryRun; 'shell still alive after the script'" 2>&1)"
expect_contains "scriptblock route reaches the drive scan (no Storage cmdlets on Linux, so it says so)" "$out" "Storage commands (Get-Disk and friends) are missing"
expect_contains "scriptblock route does not close the host: it exits normally" "$out" "shell still alive after the script"

section "F. Final bytes: parse and lint exactly what was shipped"
"$PWSH" -NoLogo -NoProfile -File "$DEV/tests/parse.ps1" -Files "$RTR/windows/Format-Fat32.ps1" && ok "shipped .ps1 (CRLF) parses" || bad "shipped .ps1 does not parse"
for m in general syntax commands; do
  r="$("$PWSH" -NoLogo -NoProfile -File "$DEV/tests/analyze.ps1" -Script "$RTR/windows/Format-Fat32.ps1" -Mode $m | grep -v -E '^(PSScriptAnalyzer|available profiles|checking against)')"
  [ "$r" = "no findings" ] && ok "PSScriptAnalyzer ($m): no findings on the shipped .ps1" || { bad "PSScriptAnalyzer ($m)"; echo "$r"; }
done
check "shellcheck: shipped Linux script" shellcheck -s bash "$RTR/linux/format-fat32.sh"
check "shellcheck: shipped macOS script" shellcheck -s bash "$RTR/macos/format-fat32.sh"
if [ -n "$BASH32" ]; then check "bash -n with bash 3.2: shipped macOS script" "$BASH32" -n "$RTR/macos/format-fat32.sh"; else echo "SKIP  bash 3.2 syntax check (set BASH32)"; fi
out="$(bash "$RTR/linux/format-fat32.sh" --dry-run 2>&1)"; expect_contains "shipped Linux script runs from the extracted folder" "$out" "No USB flash drives of 25-35 GB were found"
out="$(sh "$RTR/linux/format-fat32.sh" --dry-run 2>&1)"; expect_contains "run with sh by mistake: a clear message, not a stream of syntax errors" "$out" "Please run this with bash"

section "G. Re-run all three test suites against the SHIPPED scripts"
bash "$DEV/tests/test-linux.sh" "$RTR/linux/format-fat32.sh" "$T/linuxwork" > "$T/linux.log" 2>&1; rc=$?
tail -1 "$T/linux.log"; [ "$rc" -eq 0 ] && ok "Linux suite on shipped script" || { bad "Linux suite on shipped script"; grep '^FAIL' "$T/linux.log" | head; }
"$PWSH" -NoLogo -NoProfile -File "$DEV/tests/windows-mock-tests.ps1" -ScriptPath "$RTR/windows/Format-Fat32.ps1" > "$T/win.log" 2>&1; rc=$?
tail -1 "$T/win.log"; [ "$rc" -eq 0 ] && ok "Windows mock suite on shipped (CRLF) script" || { bad "Windows mock suite"; grep '^FAIL' "$T/win.log" | head; }
for b in "$(command -v bash)" ${BASH32:+"$BASH32"}; do
  bash "$DEV/tests/test-macos.sh" "$RTR/macos/format-fat32.sh" "$b" "$T/macwork" > "$T/mac.log" 2>&1; rc=$?
  tail -1 "$T/mac.log"; [ "$rc" -eq 0 ] && ok "macOS suite on shipped script with $("$b" --version | head -1 | cut -c1-30)" || { bad "macOS suite with $b"; grep '^FAIL' "$T/mac.log" | head; }
done

printf '\n=== PACKAGE VERIFICATION: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
