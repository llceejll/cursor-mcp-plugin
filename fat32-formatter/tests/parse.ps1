param([string[]]$Files)
$bad = 0
foreach ($f in $Files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { $bad++; "PARSE ERRORS in $f"; $errors | ForEach-Object { "  line $($_.Extent.StartLineNumber): $($_.Message)" } }
    else { "parsed OK: $f ($($tokens.Count) tokens)" }
}
exit $bad
