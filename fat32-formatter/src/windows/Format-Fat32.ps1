<#
.SYNOPSIS
    Formats 32 GB USB flash drives as FAT32. Works offline - nothing is downloaded.

.DESCRIPTION
    Finds USB flash drives of about 32 GB, lets you pick one or several, erases
    them and creates one FAT32 volume on each.

    Safety rules built in:
      - Only USB drives between -MinSizeGB and -MaxSizeGB are shown.
      - The Windows drive, boot/system disks and the drive this tool is running
        from are never shown.
      - Nothing is changed until you type ERASE.
      - Each drive is checked again right before it is erased.

    Uses only tools that ship with Windows 10 / 11 (the Storage cmdlets).

.PARAMETER Label
    Name for the new volume: 1-11 letters, digits, spaces, "-" or "_". Default: USB32.

.PARAMETER MinSizeGB
    Smallest drive to show, in decimal GB (as printed on the box). Default: 25.

.PARAMETER MaxSizeGB
    Largest drive to show, in decimal GB. Default: 35.

.PARAMETER Full
    Full format (slow, checks every sector) instead of a quick format.

.PARAMETER DryRun
    Only show which drives would be offered. Changes nothing. If Windows says
    "access denied" while listing the drives, run it from an administrator
    window.

.PARAMETER Pause
    Wait for Enter before the window closes. The launcher uses this.

.EXAMPLE
    .\Format-Fat32.ps1 -DryRun

.EXAMPLE
    .\Format-Fat32.ps1 -Label MUSIC -Full
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console tool: all output is meant for the person at the keyboard.')]
[CmdletBinding()]
param(
    [string]$Label = 'USB32',
    [double]$MinSizeGB = 25,
    [double]$MaxSizeGB = 35,
    [switch]$Full,
    [switch]$DryRun,
    [switch]$Pause
)

$ToolVersion = '1.0.0'
$ToolDirectory = $PSScriptRoot
$ErrorActionPreference = 'Stop'
$script:Relaunched = $false

function Write-Note { param([string]$Text) Write-Host $Text }
function Write-Ok { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Caution { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-Problem { param([string]$Text) Write-Host $Text -ForegroundColor Red }

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-DriveSize {
    param([int64]$Bytes)
    return ('{0:N1} GB ({1:N1} GiB)' -f ($Bytes / 1e9), ($Bytes / 1GB))
}

function Get-DiskNumberOfPath {
    param([string]$Path)
    try {
        if ([string]::IsNullOrEmpty($Path)) { return -1 }
        $qualifier = Split-Path -Path $Path -Qualifier -ErrorAction Stop
        $letter = $qualifier.TrimEnd(':')
        $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
        return [int]$partition.DiskNumber
    } catch {
        return -1
    }
}

# Disks that must never be offered: the one holding Windows and the one this
# script is running from.
function Get-ProtectedDiskNumber {
    foreach ($path in @($env:SystemDrive, $ToolDirectory)) {
        $number = Get-DiskNumberOfPath -Path $path
        if ($number -ge 0) { $number }
    }
}

function Get-UsbDiskVerdict {
    param([double]$MinGB, [double]$MaxGB)
    $minBytes = [int64]($MinGB * 1e9)
    $maxBytes = [int64]($MaxGB * 1e9)
    $protected = @(Get-ProtectedDiskNumber)
    foreach ($disk in @(Get-Disk)) {
        if ($disk.BusType -ne 'USB') { continue }
        $reason = ''
        if ($disk.IsBoot -or $disk.IsSystem) {
            $reason = 'it is a boot or system disk'
        } elseif ($protected -contains [int]$disk.Number) {
            $reason = 'it holds Windows or this tool'
        } elseif ([int64]$disk.Size -lt $minBytes) {
            $reason = ('smaller than {0} GB' -f $MinGB)
        } elseif ([int64]$disk.Size -gt $maxBytes) {
            $reason = ('larger than {0} GB' -f $MaxGB)
        }
        [pscustomobject]@{ Disk = $disk; Allowed = ($reason -eq ''); Reason = $reason }
    }
}

function Get-DriveContent {
    param([int]$DiskNumber)
    $items = @()
    $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
    foreach ($partition in $partitions) {
        $letter = $partition.DriveLetter
        if ($letter -and (([int][char]$letter) -ne 0)) {
            $volumeLabel = ''
            $fileSystem = ''
            try {
                $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
                $volumeLabel = [string]$volume.FileSystemLabel
                $fileSystem = [string]$volume.FileSystem
            } catch {
                $volumeLabel = ''
            }
            $items += ('{0}: "{1}" {2}' -f $letter, $volumeLabel, $fileSystem)
        }
    }
    if ($items.Count -eq 0) { return '(no drive letter)' }
    return ($items -join '; ')
}

# What the drive looked like when it was listed. It is compared again right
# before erasing, so a drive that was swapped in the meantime is never touched.
function Get-DriveSnapshot {
    param($Disk)
    return [pscustomobject]@{
        Number   = [int]$Disk.Number
        Name     = [string]$Disk.FriendlyName
        Serial   = [string]$Disk.SerialNumber
        UniqueId = [string]$Disk.UniqueId
        Size     = [int64]$Disk.Size
        Contents = (Get-DriveContent -DiskNumber ([int]$Disk.Number))
    }
}

function Assert-DriveUnchanged {
    param($Snapshot, [double]$MinGB, [double]$MaxGB)
    $verdict = @(Get-UsbDiskVerdict -MinGB $MinGB -MaxGB $MaxGB | Where-Object { [int]$_.Disk.Number -eq $Snapshot.Number })
    if ($verdict.Count -eq 0) { throw 'it is no longer a USB drive' }
    if (-not $verdict[0].Allowed) { throw ('it can no longer be formatted: {0}' -f $verdict[0].Reason) }
    $disk = Get-Disk -Number $Snapshot.Number
    if ([int64]$disk.Size -ne $Snapshot.Size) { throw 'its size changed since it was listed' }
    if ([string]$disk.SerialNumber -ne $Snapshot.Serial) { throw 'its serial number changed since it was listed' }
    if ([string]$disk.UniqueId -ne $Snapshot.UniqueId) { throw 'its identity changed since it was listed' }
    if ([string]$disk.FriendlyName -ne $Snapshot.Name) { throw 'its name changed since it was listed' }
    return $disk
}

function Limit-Text {
    param([string]$Text, [int]$Length)
    if ($Text.Length -le $Length) { return $Text }
    return ($Text.Substring(0, $Length - 1) + '~')
}

function Show-Candidate {
    param($Snapshots)
    Write-Note ''
    Write-Note ('  {0,-4} {1,-5} {2,-24} {3,-26} {4}' -f 'No.', 'Disk', 'Size', 'Drive', 'On it now')
    $index = 0
    foreach ($snapshot in $Snapshots) {
        $index++
        Write-Note ('  {0,-4} {1,-5} {2,-24} {3,-26} {4}' -f $index, $snapshot.Number, (Format-DriveSize $snapshot.Size), (Limit-Text $snapshot.Name 26), $snapshot.Contents)
    }
    Write-Note ''
}

function Show-IgnoredUsbDisk {
    param($Verdicts)
    $ignored = @($Verdicts | Where-Object { -not $_.Allowed })
    if ($ignored.Count -eq 0) { return }
    Write-Note 'USB drives that were ignored:'
    foreach ($verdict in $ignored) {
        Write-Note ('  Disk {0}  {1}  {2}  - {3}' -f $verdict.Disk.Number, $verdict.Disk.FriendlyName, (Format-DriveSize ([int64]$verdict.Disk.Size)), $verdict.Reason)
    }
}

# Returns the chosen list numbers, or $null when the user wants to quit.
function Read-Selection {
    param([int]$Count)
    while ($true) {
        $answer = Read-Host 'Type the number(s) of the drive(s) to ERASE (example: 1 or 1,2), ALL, or Q to quit'
        if ($null -eq $answer) { return $null }
        $answer = $answer.Trim()
        if ($answer -match '^(q|quit|exit)$') { return $null }
        if ($answer -match '^all$') { return @(1..$Count) }
        $tokens = @($answer -split '[,\s]+' | Where-Object { $_ -ne '' })
        $valid = ($tokens.Count -gt 0)
        $picked = @()
        foreach ($token in $tokens) {
            $number = 0
            if ([int]::TryParse($token, [ref]$number) -and ($number -ge 1) -and ($number -le $Count)) {
                $picked += $number
            } else {
                $valid = $false
            }
        }
        if ($valid) { return @($picked | Sort-Object -Unique) }
        Write-Caution ('Please enter numbers between 1 and {0}, ALL, or Q.' -f $Count)
    }
}

function Confirm-Erase {
    param($Snapshots)
    Write-Note ''
    Write-Caution 'These drives will be ERASED. Everything on them will be lost for good:'
    foreach ($snapshot in $Snapshots) {
        Write-Caution ('  Disk {0}: {1}  {2}  [{3}]' -f $snapshot.Number, $snapshot.Name, (Format-DriveSize $snapshot.Size), $snapshot.Contents)
    }
    $answer = Read-Host 'Type ERASE (all capitals) to continue, anything else cancels'
    $typed = ''
    if ($null -ne $answer) { $typed = ([string]$answer).Trim() }
    return ($typed -ceq 'ERASE')
}

function Get-FailureHint {
    param([string]$Message)
    if ($Message -match 'not supported|too (big|large)') {
        return 'Windows cannot create a FAT32 volume larger than 32 GB. Is this drive really a 32 GB drive?'
    }
    if ($Message -match 'denied|in use|being used') {
        return 'Close File Explorer windows and any program that uses the drive, then try again.'
    }
    if ($Message -match 'protect|read-only|read only') {
        return 'The drive is write-protected. Check for a lock switch on the drive.'
    }
    return ''
}

function Invoke-FormatDrive {
    param($Snapshot, [string]$VolumeLabel, [bool]$FullFormat, [double]$MinGB, [double]$MaxGB)
    $result = [pscustomobject]@{ Disk = $Snapshot.Number; Ok = $false; Detail = '' }
    $tag = ('[Disk {0}]' -f $Snapshot.Number)
    try {
        Write-Note ''
        Write-Note ('{0} checking...' -f $tag)
        $disk = Assert-DriveUnchanged -Snapshot $Snapshot -MinGB $MinGB -MaxGB $MaxGB
        $number = [int]$disk.Number

        if ($disk.IsOffline) { Set-Disk -Number $number -IsOffline $false }
        if ($disk.IsReadOnly) { Set-Disk -Number $number -IsReadOnly $false }

        if ($disk.PartitionStyle -ne 'RAW') {
            Write-Note ('{0} erasing the old partitions...' -f $tag)
            Clear-Disk -Number $number -RemoveData -RemoveOEM -Confirm:$false
        }

        Write-Note ('{0} creating a partition table with one FAT32 partition...' -f $tag)
        Initialize-Disk -Number $number -PartitionStyle MBR
        $partition = New-Partition -DiskNumber $number -UseMaximumSize -MbrType FAT32 -AssignDriveLetter

        if ($FullFormat) {
            Write-Note ('{0} formatting as FAT32, label {1} (full format - this can take a long time)...' -f $tag, $VolumeLabel)
        } else {
            Write-Note ('{0} formatting as FAT32, label {1} (quick format)...' -f $tag, $VolumeLabel)
        }
        $partition | Format-Volume -FileSystem FAT32 -NewFileSystemLabel $VolumeLabel -Full:$FullFormat -Force -Confirm:$false | Out-Null

        Write-Note ('{0} verifying...' -f $tag)
        $partition = Get-Partition -DiskNumber $number -PartitionNumber $partition.PartitionNumber
        $volume = $partition | Get-Volume
        if ([string]$volume.FileSystem -ne 'FAT32') {
            throw ('Windows reports the file system as "{0}", expected FAT32' -f $volume.FileSystem)
        }
        if ([string]$volume.FileSystemLabel -ne $VolumeLabel) {
            throw ('the label is "{0}", expected "{1}"' -f $volume.FileSystemLabel, $VolumeLabel)
        }
        $where = ''
        if ($volume.DriveLetter -and (([int][char]$volume.DriveLetter) -ne 0)) { $where = ('{0}:  ' -f $volume.DriveLetter) }
        $result.Ok = $true
        $result.Detail = ('{0}FAT32  {1}  {2}' -f $where, $VolumeLabel, (Format-DriveSize ([int64]$volume.Size)))
        Write-Ok ('{0} done.' -f $tag)
    } catch {
        $message = $_.Exception.Message
        $hint = Get-FailureHint -Message $message
        if ($hint -ne '') { $message = ('{0}. {1}' -f $message.TrimEnd('.'), $hint) }
        $result.Detail = $message
        Write-Problem ('{0} failed: {1}' -f $tag, $message)
    }
    return $result
}

# Windows pops up "You need to format the disk" for each new partition. Pause
# that service while we work, and always start it again afterwards.
function Suspend-ShellPrompt {
    try {
        $service = Get-Service -Name ShellHWDetection -ErrorAction Stop
        if ($service.Status -eq 'Running') {
            Stop-Service -Name ShellHWDetection -Force -ErrorAction Stop
            return $true
        }
    } catch {
        return $false
    }
    return $false
}

function Resume-ShellPrompt {
    param([bool]$WasRunning)
    if (-not $WasRunning) { return }
    try { Start-Service -Name ShellHWDetection -ErrorAction Stop } catch { Write-Caution 'Note: restart Windows if AutoPlay stops working.' }
}

function Request-Elevation {
    param([string]$VolumeLabel, [double]$MinGB, [double]$MaxGB, [bool]$FullFormat)
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Write-Problem 'This tool needs administrator rights.'
        Write-Note 'Open "Windows PowerShell (Admin)" from the Start menu and run it again.'
        return 1
    }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $argText = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Pause -Label "{1}" -MinSizeGB {2} -MaxSizeGB {3}' -f $PSCommandPath, $VolumeLabel, $MinGB.ToString($culture), $MaxGB.ToString($culture)
    if ($FullFormat) { $argText += ' -Full' }
    try {
        Write-Note 'Asking Windows for administrator permission...'
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -ArgumentList $argText -Verb RunAs
        $script:Relaunched = $true
        return 0
    } catch {
        Write-Problem ('Administrator permission was not granted: {0}' -f $_.Exception.Message)
        return 1
    }
}

function Test-QuitAnswer {
    param($Answer)
    if ($null -eq $Answer) { return $true }
    return ([string]$Answer).Trim() -match '^(q|quit|exit)$'
}

function Invoke-Main {
    param([string]$VolumeLabel, [double]$MinGB, [double]$MaxGB, [bool]$FullFormat, [bool]$DryRunMode)

    Write-Note ''
    Write-Note ('FAT32 flash drive formatter v{0}  (offline - nothing is downloaded)' -f $ToolVersion)

    if ($VolumeLabel -notmatch '^[A-Za-z0-9 _-]{1,11}$') {
        Write-Problem 'The label must be 1-11 letters, digits, spaces, "-" or "_".'
        return 2
    }
    $VolumeLabel = $VolumeLabel.ToUpper()
    if (($MinGB -le 0) -or ($MaxGB -le $MinGB)) {
        Write-Problem '-MaxSizeGB must be larger than -MinSizeGB, and both must be above 0.'
        return 2
    }
    Write-Note ('Formats USB drives of {0}-{1} GB as one FAT32 volume named {2}.' -f $MinGB, $MaxGB, $VolumeLabel)

    if (-not (Get-Command -Name Get-Disk -ErrorAction SilentlyContinue)) {
        Write-Problem 'The Windows Storage commands (Get-Disk and friends) are missing, so this tool cannot run here.'
        Write-Note 'It needs Windows 10 or 11 (or Windows 8 / Server 2012 or newer) with Windows PowerShell.'
        return 1
    }

    if ((-not $DryRunMode) -and (-not (Test-IsAdmin))) {
        return (Request-Elevation -VolumeLabel $VolumeLabel -MinGB $MinGB -MaxGB $MaxGB -FullFormat $FullFormat)
    }

    $anyFailure = $false
    $promptsWerePaused = $false
    try {
        while ($true) {
            $verdicts = @(Get-UsbDiskVerdict -MinGB $MinGB -MaxGB $MaxGB)
            $snapshots = @($verdicts | Where-Object { $_.Allowed } | ForEach-Object { Get-DriveSnapshot -Disk $_.Disk })

            if ($snapshots.Count -eq 0) {
                Write-Note ''
                Write-Caution ('No USB flash drives of {0}-{1} GB were found.' -f $MinGB, $MaxGB)
                Show-IgnoredUsbDisk -Verdicts $verdicts
                if ($DryRunMode) { break }
                $answer = Read-Host 'Plug a drive in, then press Enter to scan again (or type Q to quit)'
                if (Test-QuitAnswer -Answer $answer) { break }
                continue
            }

            Show-Candidate -Snapshots $snapshots
            Show-IgnoredUsbDisk -Verdicts $verdicts
            if ($DryRunMode) {
                Write-Caution 'DRY RUN: nothing was changed. Without -DryRun you could erase and format the drives above.'
                break
            }

            $picked = Read-Selection -Count $snapshots.Count
            if ($null -eq $picked) { break }
            $chosen = @($picked | ForEach-Object { $snapshots[$_ - 1] })
            if (-not (Confirm-Erase -Snapshots $chosen)) {
                Write-Note 'Cancelled. Nothing was changed.'
                continue
            }

            $promptsWerePaused = Suspend-ShellPrompt
            $results = @()
            try {
                foreach ($snapshot in $chosen) {
                    $results += Invoke-FormatDrive -Snapshot $snapshot -VolumeLabel $VolumeLabel -FullFormat $FullFormat -MinGB $MinGB -MaxGB $MaxGB
                }
            } finally {
                Resume-ShellPrompt -WasRunning $promptsWerePaused
                $promptsWerePaused = $false
            }

            Write-Note ''
            Write-Note 'Summary'
            foreach ($item in $results) {
                if ($item.Ok) {
                    Write-Ok ('  OK      Disk {0}  {1}' -f $item.Disk, $item.Detail)
                } else {
                    $anyFailure = $true
                    Write-Problem ('  FAILED  Disk {0}  {1}' -f $item.Disk, $item.Detail)
                }
            }
            Write-Note ''
            $answer = Read-Host 'Swap in more drives and press Enter to scan again (or type Q to quit)'
            if (Test-QuitAnswer -Answer $answer) { break }
        }
    } finally {
        Resume-ShellPrompt -WasRunning $promptsWerePaused
    }

    if ($anyFailure) { return 1 }
    return 0
}

# Run only when executed, not when dot-sourced (the tests dot-source this file).
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $exitCode = Invoke-Main -VolumeLabel $Label -MinGB $MinSizeGB -MaxGB $MaxSizeGB -FullFormat ([bool]$Full) -DryRunMode ([bool]$DryRun)
    } catch {
        Write-Problem ('Unexpected error: {0}' -f $_.Exception.Message)
        $isAdmin = $true
        try { $isAdmin = Test-IsAdmin } catch { $isAdmin = $true }
        if (-not $isAdmin) {
            Write-Note 'You are not running as administrator. Try again from "Windows PowerShell (Admin)".'
        }
    } finally {
        if ($Pause -and (-not $script:Relaunched)) {
            [void](Read-Host 'Press Enter to close this window')
        }
    }
    if ($PSCommandPath) { exit $exitCode }
}
