param([string]$Script, [string]$Mode)
$ErrorActionPreference = 'Stop'
# PSSA_MODULE can point at a saved copy (Save-PSResource PSScriptAnalyzer -Path ...); otherwise use ../psmodules or an installed module.
$localCopy = Join-Path $PSScriptRoot '../psmodules/PSScriptAnalyzer'
if ($env:PSSA_MODULE) { Import-Module $env:PSSA_MODULE }
elseif (Test-Path $localCopy) { Import-Module $localCopy }
else { Import-Module PSScriptAnalyzer }
$mod = Get-Module PSScriptAnalyzer
"PSScriptAnalyzer $($mod.Version)"
if ($Mode -eq 'general') {
    $r = Invoke-ScriptAnalyzer -Path $Script -Severity Error,Warning,Information
} elseif ($Mode -eq 'syntax') {
    $settings = @{ IncludeRules = @('PSUseCompatibleSyntax'); Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } }
    $r = Invoke-ScriptAnalyzer -Path $Script -Settings $settings
} else {
    # Cmdlet and parameter availability in real Windows PowerShell 5.1 profiles that ship with the analyzer
    $profiles = @(Get-ChildItem (Join-Path $mod.ModuleBase 'compatibility_profiles') -Filter '*.json' | ForEach-Object { $_.BaseName })
    "available profiles: " + ($profiles -join ', ')
    $targets = @($profiles | Where-Object { $_ -match '5\.1' -and $_ -match '^win-' })
    "checking against: " + ($targets -join ', ')
    $settings = @{ IncludeRules = @('PSUseCompatibleCommands'); Rules = @{ PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = $targets } } }
    $r = Invoke-ScriptAnalyzer -Path $Script -Settings $settings
}
if ($r) { $r | ForEach-Object { "{0} {1}:{2} {3}" -f $_.Severity, $_.RuleName, $_.Line, $_.Message } } else { "no findings" }
