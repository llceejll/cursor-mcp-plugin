<#
  Logic tests for windows/Format-Fat32.ps1 using mocked Storage cmdlets.

  This runs under PowerShell 7 on Linux, where Get-Disk / Format-Volume and friends do not
  exist, so they are replaced by recording fakes. What this proves: which drives are offered
  or refused, the confirmation flow, the exact order and arguments of the destructive
  cmdlet calls, failure handling, and the elevation relaunch. What it cannot prove: how the
  real Windows Storage cmdlets behave on real hardware.

  usage: pwsh -File windows-mock-tests.ps1 -ScriptPath ./Format-Fat32.ps1
#>
param([Parameter(Mandatory = $true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
function Out-Line { param([string]$Text) [Console]::WriteLine($Text) }
function Section { param([string]$Title) Out-Line ''; Out-Line ('=== {0} ===' -f $Title) }
function Assert-True {
    param([string]$Name, $Condition)
    if ($Condition) { $script:Pass++; Out-Line ('PASS  ' + $Name) } else { $script:Fail++; Out-Line ('FAIL  ' + $Name) }
}
function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $a = ($Actual -join ',')
    $e = ($Expected -join ',')
    if ($a -ceq $e) { $script:Pass++; Out-Line ('PASS  {0} (= {1})' -f $Name, $e) } else { $script:Fail++; Out-Line ('FAIL  {0}: got [{1}], wanted [{2}]' -f $Name, $a, $e) }
}

# Load the functions. The script only runs its main flow when executed, not when dot-sourced.
. $ScriptPath
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ the fake machine
$global:Mock = $null
function Reset-Mock {
    $global:Mock = @{
        Disks      = @()
        Partitions = @{}
        Volumes    = @{}
        Calls      = New-Object System.Collections.ArrayList
        Out        = New-Object System.Collections.ArrayList
        Prompts    = New-Object System.Collections.ArrayList
        Answers    = New-Object System.Collections.Queue
        NextLetter = 72
        FormatFail = @{}
        FormatAs   = @{}
        Service    = 'Running'
    }
}
function New-MockDisk {
    param([int]$Number, [string]$Name, [int64]$Size, [string]$Bus = 'USB', [bool]$Boot = $false, [bool]$System = $false,
        [string]$Style = 'MBR', [bool]$Offline = $false, [bool]$ReadOnly = $false)
    [pscustomobject]@{
        Number = $Number; FriendlyName = $Name; Size = $Size; BusType = $Bus; IsBoot = $Boot; IsSystem = $System
        PartitionStyle = $Style; SerialNumber = ('SN{0}' -f $Number); UniqueId = ('UID{0}' -f $Number)
        IsOffline = $Offline; IsReadOnly = $ReadOnly
    }
}
function Add-MockPartition {
    param([int]$Disk, [int]$Number, $Letter, [string]$Label = '', [string]$Fs = '', [int64]$Size = 1000)
    $existing = @(@($global:Mock.Partitions[$Disk]) | Where-Object { $_ })
    $part = [pscustomobject]@{ DiskNumber = $Disk; PartitionNumber = $Number; DriveLetter = $Letter }
    $global:Mock.Partitions[$Disk] = @($existing) + @($part)
    if ($Letter -and ([int][char]$Letter) -ne 0) {
        $global:Mock.Volumes[[string]$Letter] = [pscustomobject]@{ DriveLetter = $Letter; FileSystem = $Fs; FileSystemLabel = $Label; Size = $Size }
    }
}
function Record { param([string]$Text) [void]$global:Mock.Calls.Add($Text) }

# ---- fakes for the Windows Storage cmdlets and friends (they shadow the real names) ----
function Write-Host {
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [System.ConsoleColor]$ForegroundColor, [switch]$NoNewline)
    [void]$global:Mock.Out.Add(($Object -join ' '))
}
function Read-Host {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Prompt)
    [void]$global:Mock.Prompts.Add($Prompt)
    if ($global:Mock.Answers.Count -eq 0) { return $null }
    $next = $global:Mock.Answers.Dequeue()
    if ($next -is [scriptblock]) { return (& $next) }
    return $next
}
function Get-Disk {
    [CmdletBinding()]
    param([int]$Number = -1)
    if ($Number -ge 0) {
        $found = @($global:Mock.Disks | Where-Object { $_.Number -eq $Number })
        if ($found.Count -eq 0) { throw ("No MSFT_Disk objects found with property 'Number' equal to '{0}'." -f $Number) }
        return $found[0]
    }
    return $global:Mock.Disks
}
function Get-Partition {
    [CmdletBinding()]
    param([int]$DiskNumber = -1, [string]$DriveLetter, [int]$PartitionNumber = -1)
    if ($DriveLetter) {
        foreach ($key in @($global:Mock.Partitions.Keys)) {
            foreach ($p in @($global:Mock.Partitions[$key])) {
                if ($p -and ([string]$p.DriveLetter -eq $DriveLetter)) { return $p }
            }
        }
        throw ("No MSFT_Partition objects found with property 'DriveLetter' equal to '{0}'." -f $DriveLetter)
    }
    $parts = @($global:Mock.Partitions[$DiskNumber]) | Where-Object { $_ }
    if ($PartitionNumber -ge 0) { $parts = @($parts | Where-Object { $_.PartitionNumber -eq $PartitionNumber }) }
    return $parts
}
function Get-Volume {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$Partition, [string]$DriveLetter)
    process {
        if ($DriveLetter) {
            if (-not $global:Mock.Volumes.ContainsKey($DriveLetter)) { throw 'No MSFT_Volume objects found.' }
            return $global:Mock.Volumes[$DriveLetter]
        }
        if ($Partition) { return $global:Mock.Volumes[[string]$Partition.DriveLetter] }
    }
}
function Set-Disk {
    [CmdletBinding()]
    param([int]$Number, $IsOffline, $IsReadOnly)
    if ($PSBoundParameters.ContainsKey('IsOffline')) { Record ('Set-Disk {0} IsOffline={1}' -f $Number, $IsOffline) }
    if ($PSBoundParameters.ContainsKey('IsReadOnly')) { Record ('Set-Disk {0} IsReadOnly={1}' -f $Number, $IsReadOnly) }
}
function Clear-Disk {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([int]$Number, [switch]$RemoveData, [switch]$RemoveOEM)
    Record ('Clear-Disk {0} RemoveData={1} RemoveOEM={2} Confirm={3}' -f $Number, $RemoveData.IsPresent, $RemoveOEM.IsPresent, $ConfirmPreference)
    $global:Mock.Partitions[$Number] = @()
    (@($global:Mock.Disks | Where-Object { $_.Number -eq $Number }))[0].PartitionStyle = 'RAW'
}
function Initialize-Disk {
    [CmdletBinding()]
    param([int]$Number, [string]$PartitionStyle)
    Record ('Initialize-Disk {0} {1}' -f $Number, $PartitionStyle)
    (@($global:Mock.Disks | Where-Object { $_.Number -eq $Number }))[0].PartitionStyle = $PartitionStyle
}
function New-Partition {
    [CmdletBinding()]
    param([int]$DiskNumber, [switch]$UseMaximumSize, [string]$MbrType, [switch]$AssignDriveLetter)
    $letter = [char]$global:Mock.NextLetter
    $global:Mock.NextLetter++
    Record ('New-Partition {0} UseMaximumSize={1} MbrType={2} AssignDriveLetter={3}' -f $DiskNumber, $UseMaximumSize.IsPresent, $MbrType, $AssignDriveLetter.IsPresent)
    Add-MockPartition -Disk $DiskNumber -Number 1 -Letter $letter -Label '' -Fs '' -Size 31000000000
    return (@($global:Mock.Partitions[$DiskNumber]) | Where-Object { $_.PartitionNumber -eq 1 })[0]
}
function Format-Volume {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(ValueFromPipeline = $true)]$Partition, [string]$FileSystem, [string]$NewFileSystemLabel, [switch]$Full, [switch]$Force)
    process {
        Record ('Format-Volume disk={0} FileSystem={1} Label={2} Full={3} Force={4} Confirm={5}' -f $Partition.DiskNumber, $FileSystem, $NewFileSystemLabel, $Full.IsPresent, $Force.IsPresent, $ConfirmPreference)
        if ($global:Mock.FormatFail.ContainsKey([int]$Partition.DiskNumber)) { throw $global:Mock.FormatFail[[int]$Partition.DiskNumber] }
        $fs = $FileSystem
        if ($global:Mock.FormatAs.ContainsKey([int]$Partition.DiskNumber)) { $fs = $global:Mock.FormatAs[[int]$Partition.DiskNumber] }
        $vol = $global:Mock.Volumes[[string]$Partition.DriveLetter]
        $vol.FileSystem = $fs
        $vol.FileSystemLabel = $NewFileSystemLabel
        return $vol
    }
}
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)
    [pscustomobject]@{ Name = $Name; Status = $global:Mock.Service }
}
function Stop-Service {
    [CmdletBinding()]
    param([string]$Name, [switch]$Force)
    Record ('Stop-Service {0}' -f $Name)
    $global:Mock.Service = 'Stopped'
}
function Start-Service {
    [CmdletBinding()]
    param([string]$Name)
    Record ('Start-Service {0}' -f $Name)
    $global:Mock.Service = 'Running'
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$ArgumentList, [string]$Verb)
    Record ('Start-Process verb={0} args={1}' -f $Verb, $ArgumentList)
}

# Script state the real machine would provide
$env:SystemDrive = 'C:'
function Test-IsAdmin { return $true }

function Build-Machine {
    Reset-Mock
    $g = 1e9
    $d = $global:Mock.Disks
    $d += New-MockDisk -Number 0 -Name 'Samsung SSD 980 500GB' -Size 500107862016 -Bus 'NVMe' -Boot $true -System $true -Style 'GPT'
    $d += New-MockDisk -Number 1 -Name 'SanDisk Ultra USB 3.0' -Size 31914983424
    $d += New-MockDisk -Number 2 -Name 'Kingston DataTraveler' -Size 30765219840
    $d += New-MockDisk -Number 3 -Name 'Generic Flash Disk 16GB' -Size 15376000000
    $d += New-MockDisk -Number 4 -Name 'Lexar USB Flash Drive 64GB' -Size 63864569856
    $d += New-MockDisk -Number 5 -Name 'WD Elements 2TB' -Size 2000398934016
    $d += New-MockDisk -Number 6 -Name 'Windows To Go stick' -Size 31000000000 -Boot $true -System $true
    $d += New-MockDisk -Number 7 -Name 'Toolkit stick (runs this tool)' -Size 31000000000
    $d += New-MockDisk -Number 8 -Name 'Internal SATA 32GB' -Size 31914983424 -Bus 'SATA'
    $global:Mock.Disks = $d
    Add-MockPartition -Disk 0 -Number 1 -Letter 'C' -Label 'Windows' -Fs 'NTFS'
    Add-MockPartition -Disk 1 -Number 1 -Letter 'E' -Label 'MUSIC' -Fs 'exFAT'
    Add-MockPartition -Disk 2 -Number 1 -Letter 'F' -Label '' -Fs 'FAT32'
    Add-MockPartition -Disk 2 -Number 2 -Letter ([char]0)
    Add-MockPartition -Disk 7 -Number 1 -Letter 'G' -Label 'TOOLS' -Fs 'FAT32'
    $script:ToolDirectory = 'G:\Tools'
}
function Answers { param([object[]]$Items) foreach ($i in $Items) { $global:Mock.Answers.Enqueue($i) } }
function Mutations { @($global:Mock.Calls | Where-Object { $_ -match '^(Clear-Disk|Initialize-Disk|New-Partition|Format-Volume|Set-Disk)' }) }
function Show-Transcript { param([string]$Title) Out-Line ('--- {0} ---' -f $Title); foreach ($l in $global:Mock.Out) { Out-Line ('  | ' + $l) } }
function Run-Main {
    param([string]$Label = 'USB32', [double]$Min = 25, [double]$Max = 35, [bool]$FullFormat = $false, [bool]$Dry = $false)
    Invoke-Main -VolumeLabel $Label -MinGB $Min -MaxGB $Max -FullFormat $FullFormat -DryRunMode $Dry
}

Out-Line ('PowerShell {0} on {1}; script under test: {2}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.Platform, $ScriptPath)

# ------------------------------------------------------------------------------
Section '1. Which drives are offered, and why the others are not'
Build-Machine
$verdicts = @(Get-UsbDiskVerdict -MinGB 25 -MaxGB 35)
$byNumber = @{}
foreach ($v in $verdicts) { $byNumber[[int]$v.Disk.Number] = $v }
Assert-Equal 'drives offered' (@($verdicts | Where-Object { $_.Allowed } | ForEach-Object { [int]$_.Disk.Number } | Sort-Object)) @(1, 2)
Assert-Equal 'internal NVMe system disk never considered' ($byNumber.ContainsKey(0)) $false
Assert-Equal 'internal SATA disk never considered (not USB)' ($byNumber.ContainsKey(8)) $false
Assert-Equal '16 GB stick refused' $byNumber[3].Reason 'smaller than 25 GB'
Assert-Equal '64 GB stick refused' $byNumber[4].Reason 'larger than 35 GB'
Assert-Equal '2 TB USB disk refused' $byNumber[5].Reason 'larger than 35 GB'
Assert-Equal 'Windows To Go boot stick refused' $byNumber[6].Reason 'it is a boot or system disk'
Assert-Equal 'stick that holds this tool refused' $byNumber[7].Reason 'it holds Windows or this tool'
$wide = @(Get-UsbDiskVerdict -MinGB 1 -MaxGB 100000)
Assert-Equal 'with a huge range the boot and tool disks are STILL refused' (@($wide | Where-Object { -not $_.Allowed -and $_.Reason -match 'boot|holds' } | ForEach-Object { [int]$_.Disk.Number } | Sort-Object)) @(6, 7)
$global:Mock.Disks += New-MockDisk -Number 20 -Name 'Edge 25.0' -Size 25000000000
$global:Mock.Disks += New-MockDisk -Number 21 -Name 'Edge 35.0' -Size 35000000000
$global:Mock.Disks += New-MockDisk -Number 22 -Name 'Edge 24.99' -Size 24999999999
$global:Mock.Disks += New-MockDisk -Number 23 -Name 'Edge 35.01' -Size 35000000001
Assert-Equal 'boundary sizes (25.0 and 35.0 allowed; one byte outside refused)' (@(Get-UsbDiskVerdict -MinGB 25 -MaxGB 35 | Where-Object { $_.Allowed } | ForEach-Object { [int]$_.Disk.Number } | Sort-Object)) @(1, 2, 20, 21)

Section '2. What is shown for each drive'
Build-Machine
Assert-Equal 'drive with a letter shows letter, label and file system' (Get-DriveContent -DiskNumber 1) 'E: "MUSIC" exFAT'
Assert-Equal 'a partition without a letter (NUL char) is skipped' (Get-DriveContent -DiskNumber 2) 'F: "" FAT32'
Assert-Equal 'a disk with no partitions' (Get-DriveContent -DiskNumber 3) '(no drive letter)'
Assert-Equal 'path -> disk number: tool on G:' (Get-DiskNumberOfPath -Path 'G:\Tools') 7
Assert-Equal 'path -> disk number: Windows on C:' (Get-DiskNumberOfPath -Path 'C:') 0
Assert-Equal 'path -> disk number: UNC path has no drive' (Get-DiskNumberOfPath -Path '\\server\share\tools') -1
Assert-Equal 'path -> disk number: unknown drive Z:' (Get-DiskNumberOfPath -Path 'Z:\x') -1
Assert-Equal 'path -> disk number: empty path' (Get-DiskNumberOfPath -Path '') -1
Assert-Equal 'size text' (Format-DriveSize 31914983424) '31.9 GB (29.7 GiB)'

Section '3. Dry run: lists drives, asks nothing, changes nothing'
Build-Machine
$code = Run-Main -Dry $true
Show-Transcript 'dry run output'
Assert-Equal 'exit code' $code 0
Assert-True 'lists disk 1' (($global:Mock.Out -join "`n") -match 'SanDisk Ultra USB 3.0')
Assert-True 'lists disk 2' (($global:Mock.Out -join "`n") -match 'Kingston DataTraveler')
Assert-True 'shows what is on disk 1 now' (($global:Mock.Out -join "`n") -match 'E: "MUSIC" exFAT')
Assert-True 'mentions ignored USB drives' (($global:Mock.Out -join "`n") -match 'USB drives that were ignored')
Assert-True 'says nothing was changed' (($global:Mock.Out -join "`n") -match 'DRY RUN: nothing was changed')
Assert-Equal 'no destructive cmdlet was called' (Mutations).Count 0
Assert-Equal 'no question was asked' $global:Mock.Prompts.Count 0

Section '4. Normal run: pick 1 and 2, type ERASE, then quit'
Build-Machine
Answers @('1,2', 'ERASE', 'q')
$code = Run-Main
Show-Transcript 'normal run output'
Out-Line '--- destructive calls, in order ---'
foreach ($c in $global:Mock.Calls) { Out-Line ('  > ' + $c) }
Assert-Equal 'exit code' $code 0
$expected = @(
    'Stop-Service ShellHWDetection',
    'Clear-Disk 1 RemoveData=True RemoveOEM=True Confirm=None',
    'Initialize-Disk 1 MBR',
    'New-Partition 1 UseMaximumSize=True MbrType=FAT32 AssignDriveLetter=True',
    'Format-Volume disk=1 FileSystem=FAT32 Label=USB32 Full=False Force=True Confirm=None',
    'Clear-Disk 2 RemoveData=True RemoveOEM=True Confirm=None',
    'Initialize-Disk 2 MBR',
    'New-Partition 2 UseMaximumSize=True MbrType=FAT32 AssignDriveLetter=True',
    'Format-Volume disk=2 FileSystem=FAT32 Label=USB32 Full=False Force=True Confirm=None',
    'Start-Service ShellHWDetection'
)
Assert-Equal 'exact sequence of cmdlet calls' @($global:Mock.Calls) $expected
Assert-Equal 'only disks 1 and 2 were touched' (@($global:Mock.Calls | ForEach-Object { if ($_ -match '^(?:Clear-Disk|Initialize-Disk|New-Partition) (\d+)') { $Matches[1] } } | Sort-Object -Unique)) @(1, 2)
Assert-True 'summary reports OK for both' ((@($global:Mock.Out | Where-Object { $_ -match '^  OK ' })).Count -eq 2)
Assert-True 'summary shows FAT32 and the label' (($global:Mock.Out -join "`n") -match 'OK      Disk 1  H:  FAT32  USB32')
Assert-Equal 'AutoPlay service is running again at the end' $global:Mock.Service 'Running'
Assert-True 'typed confirmation was requested before any change' ($global:Mock.Prompts.IndexOf(($global:Mock.Prompts | Where-Object { $_ -match 'Type ERASE' } | Select-Object -First 1)) -ge 0)

Section '5. Wrong confirmation, invalid menu input, duplicates, quit'
Build-Machine
Answers @('abc', '9', '0', '1,1', 'erase', '2', 'ERASE', 'q')
$code = Run-Main
Assert-Equal 'exit code' $code 0
Assert-Equal 'invalid answers were rejected 3 times' (@($global:Mock.Out | Where-Object { $_ -match 'Please enter numbers between 1 and 2' }).Count) 3
Assert-Equal 'lower-case erase cancelled the first attempt' (@($global:Mock.Out | Where-Object { $_ -match 'Cancelled. Nothing was changed' }).Count) 1
Assert-Equal 'after cancelling, only the second selection (disk 2) was erased' (@($global:Mock.Calls | Where-Object { $_ -match '^Clear-Disk' })) @('Clear-Disk 2 RemoveData=True RemoveOEM=True Confirm=None')

Build-Machine
Answers @('1,1', 'ERASE', 'q')
[void](Run-Main)
Assert-Equal 'duplicate "1,1" erases disk 1 once' (@($global:Mock.Calls | Where-Object { $_ -match '^Clear-Disk' }).Count) 1

Build-Machine
Answers @('q')
$code = Run-Main
Assert-Equal 'q at the menu: exit code' $code 0
Assert-Equal 'q at the menu: nothing changed' (Mutations).Count 0

Build-Machine
Answers @('1', '', 'q')
$code = Run-Main
Assert-Equal 'empty confirmation cancels: nothing changed' (Mutations).Count 0

Build-Machine
Answers @('1')
$code = Run-Main
Assert-Equal 'input ends before confirmation: nothing changed' (Mutations).Count 0

Build-Machine
Answers @('1', '  ERASE  ', 'q')
$code = Run-Main
Assert-Equal 'spaces around ERASE are tolerated' (@($global:Mock.Calls | Where-Object { $_ -match '^Clear-Disk 1 ' }).Count) 1

Build-Machine
Answers @('1', 'ERASE!', 'q')
$code = Run-Main
Assert-Equal 'ERASE! (anything else) cancels' (Mutations).Count 0

Build-Machine
Answers @('1', 'Erase', 'q')
$code = Run-Main
Assert-Equal 'Erase (wrong case) cancels' (Mutations).Count 0

Build-Machine
Answers @('ALL', 'ERASE', 'q')
[void](Run-Main -Label 'My Usb' -FullFormat $true)
Assert-Equal 'ALL formats both drives' (@($global:Mock.Calls | Where-Object { $_ -match '^Format-Volume' }).Count) 2
Assert-True 'label is upper-cased' (@($global:Mock.Calls | Where-Object { $_ -match 'Label=MY USB ' }).Count -eq 2)
Assert-True '-Full is passed through to Format-Volume' (@($global:Mock.Calls | Where-Object { $_ -match 'Full=True' }).Count -eq 2)

Section '6. A drive that changes between the list and the erase is skipped'
Build-Machine
$swap = { $global:Mock.Disks | Where-Object { $_.Number -eq 1 } | ForEach-Object { $_.SerialNumber = 'SOMEONE-ELSES-STICK' }; 'ERASE' }
Answers @('1,2', $swap, 'q')
$code = Run-Main
Show-Transcript 'swapped drive'
Assert-Equal 'exit code (one failure)' $code 1
Assert-True 'disk 1 was never cleared' (@($global:Mock.Calls | Where-Object { $_ -match '^Clear-Disk 1 ' }).Count -eq 0)
Assert-True 'disk 2 was still formatted' (@($global:Mock.Calls | Where-Object { $_ -match '^Format-Volume disk=2 ' }).Count -eq 1)
Assert-True 'reason is reported' (($global:Mock.Out -join "`n") -match 'FAILED  Disk 1  its serial number changed since it was listed')

Build-Machine
$grow = { $global:Mock.Disks | Where-Object { $_.Number -eq 2 } | ForEach-Object { $_.Size = 63864569856 }; 'ERASE' }
Answers @('2', $grow, 'q')
$code = Run-Main
Assert-True 'a drive that is suddenly 64 GB is skipped' ((($global:Mock.Out -join "`n") -match 'FAILED  Disk 2  it can no longer be formatted: larger than 35 GB') -and (Mutations).Count -eq 0)

Build-Machine
$unplug = { $global:Mock.Disks = @($global:Mock.Disks | Where-Object { $_.Number -ne 1 }); 'ERASE' }
Answers @('1', $unplug, 'q')
$code = Run-Main
Assert-True 'a drive that was unplugged is skipped' ((($global:Mock.Out -join "`n") -match 'FAILED  Disk 1  it is no longer a USB drive') -and (Mutations).Count -eq 0)

Build-Machine
$bootify = { $global:Mock.Disks | Where-Object { $_.Number -eq 1 } | ForEach-Object { $_.IsBoot = $true }; 'ERASE' }
Answers @('1', $bootify, 'q')
$code = Run-Main
Assert-True 'a drive that became a boot disk is skipped' ((($global:Mock.Out -join "`n") -match 'FAILED  Disk 1  it can no longer be formatted: it is a boot or system disk') -and (Mutations).Count -eq 0)

Section '7. Failures are reported, other drives continue, AutoPlay service is restored'
Build-Machine
$global:Mock.FormatFail[2] = 'Size Not Supported'
Answers @('ALL', 'ERASE', 'q')
$code = Run-Main
Show-Transcript 'format failure'
Assert-Equal 'exit code' $code 1
Assert-True 'disk 1 reported OK' (($global:Mock.Out -join "`n") -match 'OK      Disk 1')
Assert-True 'disk 2 reported FAILED with the 32 GB hint' (($global:Mock.Out -join "`n") -match 'FAILED  Disk 2  Size Not Supported\. Windows cannot create a FAT32 volume larger than 32 GB')
Assert-Equal 'AutoPlay service is running again' $global:Mock.Service 'Running'
Assert-Equal 'ShellHWDetection was stopped once and started once' (@($global:Mock.Calls | Where-Object { $_ -match 'Service' })) @('Stop-Service ShellHWDetection', 'Start-Service ShellHWDetection')

Build-Machine
$global:Mock.FormatAs[1] = 'NTFS'
Answers @('1', 'ERASE', 'q')
$code = Run-Main
Assert-True 'a volume that comes out as NTFS is reported as a failure' ((($global:Mock.Out -join "`n") -match 'FAILED  Disk 1  Windows reports the file system as "NTFS", expected FAT32') -and $code -eq 1)

Build-Machine
(@($global:Mock.Disks | Where-Object { $_.Number -eq 1 }))[0].IsOffline = $true
(@($global:Mock.Disks | Where-Object { $_.Number -eq 1 }))[0].IsReadOnly = $true
(@($global:Mock.Disks | Where-Object { $_.Number -eq 2 }))[0].PartitionStyle = 'RAW'
$global:Mock.Partitions[2] = @()
Answers @('1,2', 'ERASE', 'q')
$code = Run-Main
Assert-Equal 'offline / read-only disk is brought online and writable first' (@($global:Mock.Calls | Where-Object { $_ -match '^Set-Disk' })) @('Set-Disk 1 IsOffline=False', 'Set-Disk 1 IsReadOnly=False')
Assert-True 'a RAW disk is not cleared (nothing to clear), but is still formatted' ((@($global:Mock.Calls | Where-Object { $_ -match '^Clear-Disk 2 ' }).Count -eq 0) -and (@($global:Mock.Calls | Where-Object { $_ -match '^Format-Volume disk=2 ' }).Count -eq 1))

Section '8. Nothing plugged in'
Reset-Mock
$global:Mock.Disks = @(New-MockDisk -Number 0 -Name 'System' -Size 500107862016 -Bus 'NVMe' -Boot $true -System $true)
Answers @('', 'q')
$code = Run-Main
Assert-Equal 'exit code' $code 0
Assert-Equal 'asked to plug in a drive twice (Enter rescans, q quits)' (@($global:Mock.Prompts | Where-Object { $_ -match 'Plug a drive in' }).Count) 2
Assert-True 'tells the user nothing was found' (($global:Mock.Out -join "`n") -match 'No USB flash drives of 25-35 GB were found')
Build-Machine
$global:Mock.Disks = @($global:Mock.Disks | Where-Object { $_.Number -notin 1, 2 })
Answers @('q')
[void](Run-Main)
Assert-True 'lists the ignored USB drives with reasons when none qualify' ((($global:Mock.Out -join "`n") -match 'Disk 3 .*smaller than 25 GB') -and (($global:Mock.Out -join "`n") -match 'Disk 4 .*larger than 35 GB'))

Section '9. Option checks'
Build-Machine
foreach ($bad in @('bad/label', 'TWELVE-CHARS', '', 'tab	x')) {
    $code = Run-Main -Label $bad
    Assert-Equal ('label "{0}" is rejected' -f $bad) $code 2
}
Assert-Equal 'nothing touched while rejecting labels' (Mutations).Count 0
foreach ($good in @('USB32', 'my usb', 'A-b_9', 'ELEVEN-CHAR')) {
    Build-Machine
    Answers @('q')
    $code = Run-Main -Label $good
    Assert-Equal ('label "{0}" is accepted' -f $good) $code 0
}
Build-Machine
Assert-Equal 'min >= max is rejected' (Run-Main -Min 40 -Max 30) 2
Assert-Equal 'min = 0 is rejected' (Run-Main -Min 0 -Max 30) 2

Section '10. Not an administrator: relaunch elevated'
Build-Machine
function Test-IsAdmin { return $false }
$script:Relaunched = $false
$prev = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
$code = Run-Main -Label 'music' -Min 27.5 -Max 35 -FullFormat $true
[Threading.Thread]::CurrentThread.CurrentCulture = $prev
$launch = @($global:Mock.Calls | Where-Object { $_ -match '^Start-Process' })
Out-Line ('  launch: ' + ($launch -join ' '))
Assert-Equal 'exit code' $code 0
Assert-Equal 'exactly one elevated launch' $launch.Count 1
Assert-True 'uses the RunAs verb' ($launch[0] -match 'verb=RunAs')
Assert-True 'bypasses the execution policy only for this launch' ($launch[0] -match '-NoProfile -ExecutionPolicy Bypass -File "')
Assert-True 'keeps the window open with -Pause' ($launch[0] -match ' -Pause ')
Assert-True 'passes the label upper-cased and quoted' ($launch[0] -match '-Label "MUSIC"')
Assert-True 'numbers use a dot even on a German-culture machine' ($launch[0] -match '-MinSizeGB 27\.5 -MaxSizeGB 35')
Assert-True 'passes -Full through' ($launch[0] -match ' -Full$')
Assert-Equal 'nothing was changed by the unelevated copy' (Mutations).Count 0
Assert-True 'the first window is told not to pause (it just hands over)' ($script:Relaunched -eq $true)
Build-Machine
function Test-IsAdmin { return $false }
$code = Run-Main -Dry $true
Assert-Equal 'a dry run needs no administrator rights: exit code' $code 0
Assert-Equal 'a dry run does not relaunch' (@($global:Mock.Calls | Where-Object { $_ -match '^Start-Process' }).Count) 0
function Test-IsAdmin { return $true }

Section '11. Failure hints'
Assert-True 'size error' ((Get-FailureHint -Message 'Size Not Supported') -match '32 GB')
Assert-True 'access denied' ((Get-FailureHint -Message 'Access is denied.') -match 'Close File Explorer')
Assert-True 'write protected' ((Get-FailureHint -Message 'The media is write protected.') -match 'write-protected')
Assert-Equal 'unknown error gets no hint' (Get-FailureHint -Message 'Something else') ''
Assert-Equal 'our own "its size changed" message gets no FAT32 hint' (Get-FailureHint -Message 'its size changed since it was listed') ''

Section '12. Real entry point (script run as a file, not dot-sourced)'
$pwshExe = (Get-Process -Id $PID).Path
$out = & $pwshExe -NoLogo -NoProfile -File $ScriptPath -Label 'bad/label' -DryRun 2>&1 | Out-String
Assert-Equal 'bad label: exit code' $LASTEXITCODE 2
Assert-True 'bad label: message' ($out -match 'The label must be 1-11 letters')
$out = & $pwshExe -NoLogo -NoProfile -File $ScriptPath -MinSizeGB 40 -MaxSizeGB 30 -DryRun 2>&1 | Out-String
Assert-Equal 'bad range: exit code' $LASTEXITCODE 2
$out = & $pwshExe -NoLogo -NoProfile -File $ScriptPath -DryRun 2>&1 | Out-String
Assert-Equal 'no Storage cmdlets here (Linux): exit code 1' $LASTEXITCODE 1
Assert-True 'no Storage cmdlets here (Linux): says what is missing instead of a stack trace' ($out -match 'Storage commands \(Get-Disk and friends\) are missing')
Assert-True 'no Storage cmdlets here (Linux): names the Windows versions needed' ($out -match 'Windows 10 or 11')
$wrapper = Join-Path ([IO.Path]::GetTempPath()) 'fat32-throwing-get-disk.ps1'
Set-Content -Path $wrapper -Value @('function Get-Disk { throw "boom from Get-Disk" }', 'function Get-Partition { throw "no partitions" }', '& $args[0] -DryRun', 'exit $LASTEXITCODE')
$out = & $pwshExe -NoLogo -NoProfile -File $wrapper $ScriptPath 2>&1 | Out-String
Assert-Equal 'an unexpected error: exit code 1' $LASTEXITCODE 1
Assert-True 'an unexpected error: friendly one-line message' ($out -match 'Unexpected error: boom from Get-Disk')
Assert-True 'an unexpected error: no stack trace shown' (-not ($out -match 'at <ScriptBlock>|CommandNotFoundException|System\.Management'))
Remove-Item $wrapper -ErrorAction SilentlyContinue

Out-Line ''
Out-Line ('=== RESULT: {0} passed, {1} failed ===' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
