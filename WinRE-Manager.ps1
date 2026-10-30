#Requires -Version 5.1
# WinRE-Manager: interactive, one-confirmation Windows RE repair.
# Supports simple basic GPT/MBR layouts only. No shrink or partition moves.
# No log files. Changes to disk only after the final Y/N approval.

# Keep the result visible when the script is launched in its own PowerShell window.
function Wait-ForExitKey {
    try {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return }
        Write-Host ''
        Write-Host 'Press any key to finish...' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    } catch {
        # No interactive console (for example, a redirected or unattended run).
    }
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:MiB = [int64]1048576
$script:GiB = [int64]1073741824
$script:RecoveryGuid = 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC'
$script:BasicGuid = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
$script:WorkDir = $null
$script:MountDir = $null
$script:WimFile = $null
$script:Mounted = $false
$script:TempLetter = $null
$script:NewPartNumber = $null
$script:DiskNumber = $null
$script:Mutated = $false
$script:Completed = $false
$script:Failed = $false
$script:SkipExitPause = $false
$script:ResultWasReported = $false

function Say([string]$message) { Write-Host $message }
function Write-Section([string]$label) {
    Write-Host ''
    Write-Host ("=== {0} ===" -f $label) -ForegroundColor Cyan
}
function Write-Detail([string]$label, [string]$value, [string]$color = 'White') {
    Write-Host ("  {0,-17}" -f ($label + ':')) -ForegroundColor Gray -NoNewline
    Write-Host $value -ForegroundColor $color
}
function Write-Notice([string]$message) {
    Write-Host ("  {0}" -f $message) -ForegroundColor Yellow
}
function Write-Step([string]$message) {
    Write-Host ("  {0}" -f $message) -ForegroundColor White
}
function Write-Result([string]$message, [bool]$success = $true) {
    Write-Host ''
    if ($success) { Write-Host $message -ForegroundColor Green }
    else { Write-Host $message -ForegroundColor Red }
    $script:ResultWasReported = $true
}
# Ctrl+C stops the PowerShell output pipeline, which may suppress Write-Host
# in finally. Write directly to the console to make an interrupted run visible.
function Write-InterruptedNotice {
    $notice = 'INTERRUPTED: Operation stopped before completion (Ctrl+C).'
    $warning = 'Check WinRE and disk state before retrying; no rollback is performed.'
    try {
        $savedColor = [Console]::ForegroundColor
        try {
            [Console]::ForegroundColor = [ConsoleColor]::Red
            [Console]::Error.WriteLine('')
            [Console]::Error.WriteLine('=== OPERATION INTERRUPTED ===')
            [Console]::Error.WriteLine('  ' + $notice)
            if ($script:Mutated) {
                [Console]::ForegroundColor = [ConsoleColor]::Yellow
                [Console]::Error.WriteLine('  ' + $warning)
            }
        } finally {
            [Console]::ForegroundColor = $savedColor
        }
    } catch {
        # Fallback for hosts without a usable System.Console.
        Write-Host ''
        Write-Host ('=== ' + $notice + ' ===') -ForegroundColor Red
        if ($script:Mutated) { Write-Host ('  ' + $warning) -ForegroundColor Yellow }
    }
}
function SizeMiB([int64]$bytes) { '{0:N0} MiB' -f ($bytes / $script:MiB) }
function SizeGiB([int64]$bytes) { '{0:N2} GiB' -f ($bytes / $script:GiB) }
function Is-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# Prefer UNC paths for mapped drives: elevated sessions may not inherit drive mappings.
function Resolve-ElevationPath([string]$path) {
    if ($path -notmatch '^([A-Za-z]):\\') { return $path }
    $letter = $path.Substring(0, 1)
    $share = ''
    $drive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if ($drive -and $drive.PSObject.Properties['DisplayRoot'] -and $drive.DisplayRoot -and ([string]$drive.DisplayRoot).StartsWith('\\')) {
        $share = [string]$drive.DisplayRoot
    }
    if (-not $share) {
        try {
            $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $letter) -ErrorAction Stop
            if ($logical -and $logical.ProviderName) { $share = [string]$logical.ProviderName }
        } catch {
            # The original path still works for local drives.
        }
    }
    if ($share -and $share.StartsWith('\\')) {
        return ($share.TrimEnd('\\') + $path.Substring(2))
    }
    return $path
}
# Let native console tools render their own progress and diagnostics.
# Do not pipe their output through PowerShell unless it must be parsed.
function Run-External([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw ("$exe failed with exit code $exitCode.") }
}
function Run-DiskPart([string[]]$commands) {
    $name = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($name, $commands, [Text.Encoding]::ASCII)
    try { Run-External 'diskpart.exe' @('/s', $name) }
    finally { Remove-Item -LiteralPath $name -Force -ErrorAction SilentlyContinue }
}
function Get-ReInfo {
    $out = (& reagentc.exe /info 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Unable to run reagentc /info: $out" }
    $match = [regex]::Match($out, '(?im)^\s*[^:\r\n]+:\s*(Enabled|Disabled|\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e|\u041e\u0442\u043a\u043b\u044e\u0447\u0435\u043d\u043e)\s*$')
    if (-not $match.Success) { throw "Unable to parse WinRE status from reagentc output:`n$out" }
    $status = if ($match.Groups[1].Value -match '^(Enabled|\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e)$') { 'Enabled' } else { 'Disabled' }
    return [pscustomobject]@{ Status = $status; Output = $out }
}
function Is-RecoveryPartition($part, [string]$style) {
    if ($style -eq 'GPT') {
        return (([string]$part.GptType).Trim('{}') -ieq $script:RecoveryGuid)
    }
    $type = [string]$part.Type
    $mbr = if ($part.PSObject.Properties['MbrType']) { [string]$part.MbrType } else { '' }
    return (($type -ieq 'Recovery') -or ($type -ieq '0x27') -or ($mbr -ieq 'Recovery'))
}
function Get-FreeLetter {
    foreach ($letter in @('R','S','T','U','V','W','Y','Z')) {
        if (-not (Test-Path ("$letter`:")) -and @((Get-Partition | Where-Object { [string]$_.DriveLetter -ieq $letter })).Count -eq 0) {
            return $letter
        }
    }
    throw 'No free temporary drive letter (R,S,T,U,V,W,Y,Z).'
}
function Test-Wim([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $path -Force).Length -lt (100 * $script:MiB)) { return $false }
    try { $null = Get-WindowsImage -ImagePath $path -Index 1 -ErrorAction Stop; return $true }
    catch { return $false }
}
function Get-RecoveryRoot($part) {
    if ($null -eq $part) { return $null }
    $paths = @()
    try {
        $vol = Get-Volume -Partition $part -ErrorAction Stop
        if ($vol.Path) { $paths += [string]$vol.Path }
    } catch { }
    foreach ($path in @($part.AccessPaths)) { if ($path) { $paths += [string]$path } }
    foreach ($path in ($paths | Select-Object -Unique)) {
        if ($path -match '^\\\\\?\\Volume\{[0-9a-fA-F-]+\}\\?$' -and (Test-Path -LiteralPath $path)) {
            return ($path.TrimEnd('\') + '\')
        }
        if ($path -match '^[A-Z]:\\?$' -and (Test-Path -LiteralPath $path)) {
            return ($path.TrimEnd('\') + '\')
        }
    }
    return $null
}
function Find-Wim($part) {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add((Join-Path $env:windir 'System32\Recovery\Winre.wim'))
    $candidates.Add((Join-Path ($env:SystemDrive + '\') 'Recovery\WindowsRE\Winre.wim'))
    $root = Get-RecoveryRoot $part
    if ($root) {
        $candidates.Add((Join-Path $root 'Recovery\WindowsRE\Winre.wim'))
        $candidates.Add((Join-Path $root 'Winre.wim'))
    }
    foreach ($path in @($candidates | Select-Object -Unique)) {
        if (Test-Wim $path) { return $path }
    }
    return $null
}
function Get-LayoutMode($disk, $os, $part, $allParts) {
    if ([string]$disk.PartitionStyle -notin @('GPT','MBR')) { throw 'Only GPT and MBR disks are supported.' }
    if ($disk.IsOffline -or $disk.IsReadOnly) { throw 'The system disk is offline or read-only.' }
    if (-not $disk.IsBoot) { throw 'The Windows disk could not be verified as the boot disk.' }
    if ([string]$os.Type -match 'Extended') { throw 'Logical partitions are not supported.' }
    if ([string]$disk.PartitionStyle -eq 'MBR') {
        if (@($allParts | Where-Object { [string]$_.Type -match 'Extended|Logical' }).Count -gt 0) {
            throw 'MBR disks with extended or logical partitions are not supported.'
        }
        if (-not $part -and @($allParts).Count -ge 4) { throw 'MBR already has four primary partitions.' }
    }
    $endC = [int64]($os.Offset + $os.Size)
    $after = @($allParts | Where-Object { $_.Offset -ge $endC } | Sort-Object Offset)
    if ($part) {
        if ($after.Count -lt 1 -or $after[0].PartitionNumber -ne $part.PartitionNumber) {
            throw 'Recovery is not the first partition after C:. The layout is unsupported.'
        }
        if ($part.Offset -lt $endC -or ($part.Offset - $endC) -gt 2 * $script:MiB) {
            throw 'Recovery is not directly adjacent to C:.'
        }
        if ($part.IsSystem -or $part.IsBoot -or $part.IsActive) { throw 'Recovery has system or boot flags; it will not be modified.' }
        if ($after.Count -gt 1) {
            # Example: C: -> Recovery -> D:. Never delete Recovery or resize C: here.
            return 'InPlace'
        }
        return 'Rebuild'
    }
    if ($after.Count -gt 0) {
        throw 'A partition follows C: but no Recovery partition was identified. No partitions will be moved.'
    }
    return 'Rebuild'
}
function Assert-BitLockerSafe {
    $command = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $command) { throw 'Cannot check BitLocker status. Modifications are blocked.' }
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($null -eq $bl) { throw 'BitLocker status was not returned.' }
    if ([string]$bl.VolumeStatus -ne 'FullyDecrypted' -and [string]$bl.VolumeStatus -ne '0') {
        throw 'C: is encrypted or encrypting with BitLocker. Modifications are blocked.'
    }
    if ([string]$bl.ProtectionStatus -eq 'On' -or [string]$bl.ProtectionStatus -eq '1') {
        throw 'BitLocker protection is active. Modifications are blocked.'
    }
}
function Find-IsoImage([string]$letter) {
    foreach ($name in @('sources\install.wim', 'sources\install.esd')) {
        $candidate = "$letter`:\$name"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}
function Get-NormalizedArchitecture([string]$value) {
    switch -Regex ($value.Trim()) {
        '^(9|x64|AMD64)$' { return 'x64' }
        '^(12|ARM64)$' { return 'ARM64' }
        '^(0|x86|I386)$' { return 'x86' }
        default { return $value.Trim().ToUpperInvariant() }
    }
}
function Test-SharedWindows11Core([int]$installedBuild, [int]$imageBuild) {
    # Windows 11 24H2, 25H2 and 26H2 share the 26100 servicing core.
    return ($installedBuild -in @(26100,26200,26300) -and $imageBuild -in @(26100,26200,26300))
}
function Select-IsoIndex([string]$path, [string]$edition, [int]$build, [string]$arch) {
    # Architecture is detected numerically, not through localized OSArchitecture strings.
    $expectedArch = Get-NormalizedArchitecture $arch
    if ($expectedArch -notin @('x64', 'x86', 'ARM64')) {
        throw "Unsupported processor architecture: $expectedArch."
    }
    $all = @(Get-WindowsImage -ImagePath $path -ErrorAction Stop)
    if ($all.Count -eq 0) { throw 'The ISO image catalog is empty.' }

    $rows = @()
    $matching = @()
    foreach ($img in $all) {
        $detail = Get-WindowsImage -ImagePath $path -Index ([int]$img.ImageIndex) -ErrorAction Stop
        $imageEdition = [string]$detail.EditionId
        $imageArch = Get-NormalizedArchitecture ([string]$detail.Architecture)
        $imageVersion = [version]$detail.Version
        $imageBuild = [int]$imageVersion.Build
        $editionMatch = ($imageEdition -ieq $edition)
        $archMatch = ($imageArch -ieq $expectedArch)
        $exactBuild = ($imageBuild -eq $build)
        $sharedBuild = Test-SharedWindows11Core $build $imageBuild
        $rows += [pscustomobject]@{
            Index=[int]$detail.ImageIndex
            Edition=$imageEdition
            Build=$imageBuild
            Architecture=$imageArch
            Name=[string]$detail.ImageName
        }
        if ($editionMatch -and $archMatch -and ($exactBuild -or $sharedBuild)) {
            $matching += [pscustomobject]@{
                Index=[int]$detail.ImageIndex
                Edition=$imageEdition
                Build=$imageBuild
                Architecture=$imageArch
                Name=[string]$detail.ImageName
                Exact=$exactBuild
            }
        }
    }
    Write-Host ''
    Write-Host '  Available ISO images:' -ForegroundColor Gray
    $rows | Sort-Object Index | Format-Table Index, Edition, Build, Architecture, Name -AutoSize | Out-Host

    $exact = @($matching | Where-Object { $_.Exact })
    $compatible = @($matching | Where-Object { -not $_.Exact })
    $selected = $null
    if ($exact.Count -eq 1) { $selected = $exact[0] }
    elseif ($exact.Count -eq 0 -and $compatible.Count -eq 1) { $selected = $compatible[0] }

    if (-not $selected) {
        throw "No unique compatible ISO image for edition $edition, OS build $build, architecture $expectedArch (exact: $($exact.Count); shared-core: $($compatible.Count)). Check the ISO metadata above."
    }
    Write-Detail 'Selected image' ("index {0}, {1}, build {2}, {3}" -f $selected.Index, $selected.Edition, $selected.Build, $selected.Architecture) 'Green'
    if (-not $selected.Exact) {
        Write-Notice ("ISO build {0} differs from installed build {1}; accepted because both use the Windows 11 24H2/25H2/26H2 servicing core." -f $selected.Build, $build)
    }
    return [int]$selected.Index
}
function Extract-IsoWinre([string]$source, [int]$index) {
    $image = $source
    if ([IO.Path]::GetExtension($source) -ieq '.esd') {
        $image = Join-Path $script:WorkDir 'Install-Selected.wim'
        Write-Step 'Exporting selected install.esd image...'
        Write-Detail 'Temporary WIM' $image
        Run-External 'dism.exe' @('/English', '/Export-Image', "/SourceImageFile:$source", "/SourceIndex:$index", "/DestinationImageFile:$image", '/Compress:max', '/CheckIntegrity')
        Write-Step 'Image export completed.'
        $index = 1
    }
    New-Item -ItemType Directory -Path $script:MountDir -Force | Out-Null
    Write-Step 'Mounting installation image read-only...'
    Run-External 'dism.exe' @('/English','/Mount-Image',"/ImageFile:$image","/Index:$index","/MountDir:$script:MountDir",'/ReadOnly')
    $script:Mounted = $true
    $inside = Join-Path $script:MountDir 'Windows\System32\Recovery\Winre.wim'
    if (-not (Test-Path -LiteralPath $inside -PathType Leaf)) { throw 'The installation image does not contain Winre.wim.' }
    Copy-Item -LiteralPath $inside -Destination $script:WimFile -Force -ErrorAction Stop
    Write-Step 'Unmounting installation image...'
    Run-External 'dism.exe' @('/English','/Unmount-Image',"/MountDir:$script:MountDir",'/Discard')
    $script:Mounted = $false
}
function Make-Plan($disk, $os, [int64]$minSize) {
    # Explicit 4 MiB tail margin; all planned boundaries are aligned to 1 MiB.
    $end = [int64]([math]::Floor(($disk.Size - 4 * $script:MiB) / $script:MiB) * $script:MiB)
    $cEnd = [int64]($os.Offset + $os.Size)
    if ($end - $cEnd -lt $minSize) { throw ('Insufficient space after C: (including old Recovery): ' + (SizeMiB ($end - $cEnd)) + '; required ' + (SizeMiB $minSize)) }
    $maxC = [int64]($end - $os.Offset - $minSize)
    $roundedC = [int64]([math]::Floor($maxC / $script:GiB) * $script:GiB)
    $targetC = [int64]$os.Size
    # Never shrink C: and never extend to a non-round figure.
    if ($roundedC -gt $targetC -and ($roundedC - $targetC) -ge $script:MiB) { $targetC = $roundedC }
    $capacity = [int64]($end - $os.Offset - $targetC)
    $maxRecovery = [int64]($minSize + $script:GiB)
    $targetRecovery = [int64]([math]::Floor(([math]::Min($capacity,$maxRecovery)) / $script:MiB) * $script:MiB)
    if ($targetRecovery -lt $minSize) { throw 'Calculated Recovery partition is smaller than the minimum.' }
    return [pscustomobject]@{ TargetC=$targetC; Recovery=$targetRecovery; MinRecovery=$minSize; MaxRecovery=$maxRecovery; Offset=[int64]($os.Offset + $targetC) }
}
function Assert-StillSame($os, $old, [string]$identity) {
    $nowDisk = Get-Disk -Number $script:DiskNumber -ErrorAction Stop
    if ([string]$nowDisk.UniqueId -ne $identity) { throw 'The disk identifier changed after analysis.' }
    $nowC = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -ErrorAction Stop
    if ($nowC.Offset -ne $os.Offset -or $nowC.Size -ne $os.Size -or [string]$nowC.DriveLetter -ine 'C') { throw 'The C: partition changed after analysis.' }
    if ($old) {
        $nowOld = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $old.PartitionNumber -ErrorAction Stop
        if ($nowOld.Offset -ne $old.Offset -or $nowOld.Size -ne $old.Size -or -not (Is-RecoveryPartition $nowOld ([string]$nowDisk.PartitionStyle))) {
            throw 'The Recovery partition changed after analysis.'
        }
    }
}
function Assert-DiskLayoutSnapshot($snapshot) {
    $current = @(Get-Partition -DiskNumber $script:DiskNumber -ErrorAction Stop | Sort-Object Offset)
    if ($current.Count -ne $snapshot.Count) { throw 'Partition count changed after analysis.' }
    for ($i = 0; $i -lt $current.Count; $i++) {
        if ($current[$i].PartitionNumber -ne $snapshot[$i].PartitionNumber -or
            $current[$i].Offset -ne $snapshot[$i].Offset -or
            $current[$i].Size -ne $snapshot[$i].Size) {
            throw 'Disk partition layout changed after analysis.'
        }
    }
}
function Assert-OldPartitionSafe($part) {
    # Never delete a known OEM/custom recovery partition with other content.
    if (-not $part) { return }
    $root = Get-RecoveryRoot $part
    if (-not $root) { throw 'Cannot inspect the existing Recovery partition. Destructive changes are blocked.' }
    $allowed = @('Recovery', 'System Volume Information', '$RECYCLE.BIN')
    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if ($entry.Name -notin $allowed) { throw "Recovery contains an unexpected item '$($entry.Name)'. It will not be removed automatically." }
    }
    $recoveryFolder = Join-Path $root 'Recovery'
    if (Test-Path -LiteralPath $recoveryFolder) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $recoveryFolder -Force -ErrorAction Stop)) {
            if ($entry.Name -notin @('WindowsRE')) { throw "Recovery contains OEM or unrelated data '$($entry.Name)'. It will not be removed automatically." }
        }
        $windowsReFolder = Join-Path $recoveryFolder 'WindowsRE'
        if (Test-Path -LiteralPath $windowsReFolder) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $windowsReFolder -Force -ErrorAction Stop)) {
                if ($entry.PSIsContainer -or $entry.Name -notin @('Winre.wim','ReAgent.xml','boot.sdi')) {
                    throw "Recovery contains an unrecognized WindowsRE item '$($entry.Name)'; it will not be formatted."
                }
            }
        }
    }
}
function Set-RecoveryType([int]$number, [string]$style) {
    if ($style -eq 'GPT') {
        Run-DiskPart @("select disk $script:DiskNumber", "select partition $number", "set id=$script:RecoveryGuid override", 'gpt attributes=0x8000000000000001')
    } else {
        Run-DiskPart @("select disk $script:DiskNumber", "select partition $number", 'set id=27 override')
    }
    $checked = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $number
    if (-not (Is-RecoveryPartition $checked $style)) { throw 'Failed to set the Recovery partition type.' }
    if ($style -eq 'GPT' -and -not $checked.NoDefaultDriveLetter) { throw 'GPT NoDefaultDriveLetter attribute was not set.' }
}

try {
    if (-not (Is-Admin)) {
        Say 'Administrator rights are required. Requesting elevation...'
        if (-not $PSCommandPath -or -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
            throw 'Automatic elevation requires launching a saved .ps1 file.'
        }
        # UAC launches a new window. Do not wait or terminate the calling console.
        $elevationScript = Resolve-ElevationPath $PSCommandPath
        $elevationDirectory = Resolve-ElevationPath (Get-Location).ProviderPath
        $elevationArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $elevationScript + '"'
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList $elevationArgs -Verb RunAs `
            -WorkingDirectory $elevationDirectory -ErrorAction Stop | Out-Null
        Say 'Elevated PowerShell started. Continue in the new window.'
        # An existing interactive PowerShell session must remain usable.
        # A standalone non-elevated PowerShell process can close normally.
        $script:SkipExitPause = $true
        return
    }
    Import-Module Storage -ErrorAction Stop
    Import-Module Dism -ErrorAction Stop
    if ($env:SystemDrive -ine 'C:') { throw 'Only Windows installed on C: is supported.' }
    $osData = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$osData.CurrentBuildNumber
    if ($build -lt 14393) { throw 'Windows 10 and Windows Server 2016 or newer are required.' }
    $edition = [string]$osData.EditionID
    $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $arch = Get-NormalizedArchitecture ([string]$processor.Architecture)
    $os = Get-Partition -DriveLetter C -ErrorAction Stop
    $script:DiskNumber = [int]$os.DiskNumber
    $disk = Get-Disk -Number $script:DiskNumber -ErrorAction Stop
    $parts = @(Get-Partition -DiskNumber $script:DiskNumber | Sort-Object Offset)
    $recoveries = @($parts | Where-Object { Is-RecoveryPartition $_ ([string]$disk.PartitionStyle) })
    if ($recoveries.Count -gt 1) { throw 'More than one Recovery partition was found. Automatic changes are blocked.' }
    $old = if ($recoveries.Count -eq 1) { $recoveries[0] } else { $null }
    $state = Get-ReInfo
    Write-Section 'WinRE-MANAGER / ANALYSIS'
    Write-Detail 'Windows' ("$edition, build $build, $arch")
    Write-Detail 'System disk' ("$script:DiskNumber ($($disk.PartitionStyle))")
    Write-Detail 'C' (SizeGiB $os.Size)
    $statusColor = if ($state.Status -eq 'Enabled') { 'Green' } else { 'Yellow' }
    Write-Detail 'WinRE' $state.Status $statusColor
    Write-Detail 'Recovery' $(if ($old) { "partition $($old.PartitionNumber), $(SizeMiB $old.Size)" } else { 'not found' })
    if ($state.Status -eq 'Enabled') {
        Write-Result 'WinRE is already enabled. No changes are needed.'
        return
    }
    $layoutMode = Get-LayoutMode $disk $os $old $parts
    Assert-OldPartitionSafe $old
    Assert-BitLockerSafe
    # Staging is local to C:, so it survives deletion of the old Recovery.
    $script:WorkDir = Join-Path $env:windir ('Temp\WinRE-Manager-' + [guid]::NewGuid().ToString('N'))
    $script:MountDir = Join-Path $script:WorkDir 'Mount'
    $script:WimFile = Join-Path $script:WorkDir 'Winre.wim'
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    Write-Section 'IMAGE SOURCE'
    $source = Find-Wim $old
    $sourceInfo = $null
    if ($source) {
        Write-Detail 'Local Winre.wim' $source 'Green'
        Copy-Item -LiteralPath $source -Destination $script:WimFile -Force -ErrorAction Stop
        $sourceInfo = "local ($source)"
    } else {
        Write-Detail 'Local Winre.wim' 'Not found' 'Yellow'
        Write-Notice 'Mount a Windows installation ISO if it is not already mounted.'
        Write-Host ''
        $letter = (Read-Host 'ISO drive letter (e.g. F; Enter cancels)').Trim().ToUpperInvariant()
        if (-not $letter) { Write-Result 'Canceled. No partitions were changed.'; return }
        if ($letter -notmatch '^[A-Z]$') { throw 'Enter one drive letter without a colon.' }
        $install = Find-IsoImage $letter
        if (-not $install) { throw "The ISO on $letter`: does not contain sources\install.wim or install.esd." }
        Write-Detail 'Installation file' $install
        $index = Select-IsoIndex $install $edition $build $arch
        $free = [int64](Get-Volume -DriveLetter C).SizeRemaining
        $need = if ($install -like '*.esd') { 9 * $script:GiB } else { 2 * $script:GiB }
        if ($free -lt $need) { throw "ISO extraction requires at least $(SizeGiB $need) of free space on C:." }
        Extract-IsoWinre $install $index
        $sourceInfo = "ISO $letter`: (index $index)"
    }
    if (-not (Test-Wim $script:WimFile)) { throw 'The extracted Winre.wim failed DISM validation.' }
    $imageSize = [int64](Get-Item -LiteralPath $script:WimFile -Force).Length
    $minSize = [int64]([math]::Ceiling(([math]::Max(990 * $script:MiB, $imageSize + 250 * $script:MiB + 32 * $script:MiB)) / $script:MiB) * $script:MiB)
    if ($layoutMode -eq 'InPlace') {
        if ($old.Size -lt $minSize) {
            throw "Recovery is $(SizeMiB $old.Size), but at least $(SizeMiB $minSize) is needed. Other partitions will not be moved; shrinking C: is planned for a future release."
        }
        $plan = [pscustomobject]@{
            Mode='InPlace'; TargetC=[int64]$os.Size; Recovery=[int64]$old.Size;
            MinRecovery=$minSize; MaxRecovery=[int64]$old.Size;
            Offset=[int64]$old.Offset
        }
    } else {
        $plan = Make-Plan $disk $os $minSize
        $plan | Add-Member -NotePropertyName Mode -NotePropertyValue 'Rebuild'
    }
    # Do not propose an unsafe layout if a preflight check already fails.
    $identity = [string]$disk.UniqueId
    $partitionSnapshot = @($parts | ForEach-Object {
        [pscustomobject]@{ PartitionNumber=$_.PartitionNumber; Offset=$_.Offset; Size=$_.Size }
    })
    $tmpLetter = Get-FreeLetter
    Write-Section 'SUMMARY / PROPOSED PLAN'
    Write-Detail 'Image source' $sourceInfo
    Write-Detail 'Image size' (SizeMiB $imageSize)
    Write-Detail 'C: current' (SizeGiB $os.Size)
    Write-Detail 'C: proposed' (SizeGiB $plan.TargetC) $(if ($plan.TargetC -gt $os.Size) { 'Yellow' } else { 'White' })
    Write-Detail 'Recovery current' $(if ($old) { SizeMiB $old.Size } else { 'none' })
    Write-Detail 'Recovery target' (SizeMiB $plan.Recovery) 'Yellow'
    Write-Detail 'Required minimum' (SizeMiB $plan.MinRecovery)
    Write-Host ''
    Write-Host '  Planned actions:' -ForegroundColor Gray
    Write-Step '1. Try reagentc /enable; stop without repartitioning if it succeeds.'
    if ($plan.Mode -eq 'InPlace') {
        Write-Step '2. Keep C: and later partitions unchanged.'
        Write-Step ("3. Reformat Recovery partition {0}; restore and enable WinRE." -f $old.PartitionNumber)
    } else {
        if ($old) { Write-Step ("2. Delete Recovery partition {0}." -f $old.PartitionNumber) }
        else { Write-Step '2. Use unallocated space after C:.' }
        if ($plan.TargetC -gt $os.Size) { Write-Step ("3. Extend C: to {0} (no shrinking)." -f (SizeGiB $plan.TargetC)) }
        Write-Step ("4. Create and format {0} NTFS Recovery; restore WinRE." -f (SizeMiB $plan.Recovery))
    }
    Write-Section 'SAFETY'
    Write-Notice 'Any existing Recovery content will be permanently deleted if repair is required.'
    Write-Notice 'Create a complete disk backup or verified VM checkpoint before continuing.'
    Write-Host '  No partition or WinRE configuration changes were made during analysis.' -ForegroundColor DarkGray
    Write-Host '  Execution stops on the first error; there is no automatic rollback.' -ForegroundColor DarkGray
    Write-Host ''
    $decision = (Read-Host 'Apply this plan? [Y/N]').Trim().ToUpperInvariant()
    if ($decision -cne 'Y') { Write-Result 'Canceled. No system settings were changed.'; return }

    Write-Section 'EXECUTION'
    Assert-StillSame $os $old $identity
    Assert-DiskLayoutSnapshot $partitionSnapshot
    Write-Step 'Trying the standard reagentc /enable...'
    & reagentc.exe /enable
    $code = $LASTEXITCODE
    $nowState = Get-ReInfo
    if ($code -eq 0 -and $nowState.Status -eq 'Enabled') {
        Write-Result 'SUCCESS: WinRE enabled without repartitioning.'
        $script:Completed = $true
        return
    }
    if ($nowState.Status -eq 'Enabled') {
        throw 'reagentc returned an error but WinRE now reports Enabled. Manual inspection is required.'
    }
    Write-Notice 'Standard WinRE enable failed. Executing the approved recovery plan.'
    Assert-StillSame $os $old $identity
    Assert-DiskLayoutSnapshot $partitionSnapshot
    if ($plan.Mode -eq 'InPlace') {
        $script:NewPartNumber = [int]$old.PartitionNumber
        $script:TempLetter = $tmpLetter
        $script:Mutated = $true
        Run-DiskPart @("select disk $script:DiskNumber", "select partition $script:NewPartNumber", "assign letter=$tmpLetter")
        $mountedPart = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $script:NewPartNumber -ErrorAction Stop
        if ([string]$mountedPart.DriveLetter -ine $tmpLetter -or $mountedPart.Offset -ne $old.Offset -or $mountedPart.Size -ne $old.Size) {
            throw 'The existing Recovery partition could not be safely mounted.'
        }
        Say "Formatting existing Recovery partition $script:NewPartNumber. Later partitions are untouched."
        Format-Volume -Partition $mountedPart -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' -Force -Confirm:$false -ErrorAction Stop | Out-Null
    } else {
        if ($old) {
            Say "Deleting Recovery partition $($old.PartitionNumber)..."
            $script:Mutated = $true
            Run-DiskPart @("select disk $script:DiskNumber", "select partition $($old.PartitionNumber)", 'delete partition override')
            $afterDelete = @(Get-Partition -DiskNumber $script:DiskNumber | Where-Object { $_.Offset -eq $old.Offset })
            if ($afterDelete.Count -ne 0) { throw 'Recovery partition was not removed; stopping.' }
        }
        if ($plan.TargetC -gt $os.Size) {
            Say "Extending C: to $(SizeGiB $plan.TargetC)..."
            $supported = Get-PartitionSupportedSize -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -ErrorAction Stop
            if ($supported.SizeMax -lt $plan.TargetC) { throw 'Windows does not permit extending C: to the planned size.' }
            $script:Mutated = $true
            Resize-Partition -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -Size $plan.TargetC -ErrorAction Stop
        }
        $updatedC = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -ErrorAction Stop
        if ($updatedC.Offset -ne $os.Offset -or $updatedC.Size -ne $plan.TargetC) { throw 'C: does not match the approved size after resizing.' }
        $offset = [int64]($updatedC.Offset + $updatedC.Size)
        if ($offset -ne $plan.Offset) { throw 'The new Recovery offset does not match the plan.' }
        Say "Creating NTFS Recovery: $(SizeMiB $plan.Recovery)..."
        $script:Mutated = $true
        if ([string]$disk.PartitionStyle -eq 'GPT') {
            $created = New-Partition -DiskNumber $script:DiskNumber -Offset $offset -Size $plan.Recovery -DriveLetter $tmpLetter -GptType $script:BasicGuid -ErrorAction Stop
        } else {
            $created = New-Partition -DiskNumber $script:DiskNumber -Offset $offset -Size $plan.Recovery -DriveLetter $tmpLetter -MbrType IFS -ErrorAction Stop
        }
        $script:NewPartNumber = [int]$created.PartitionNumber
        $script:TempLetter = $tmpLetter
        $new = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $script:NewPartNumber
        if ($new.Offset -ne $offset -or $new.Size -lt $plan.MinRecovery -or $new.Size -ne $plan.Recovery -or [string]$new.DriveLetter -ine $tmpLetter) {
            throw 'Created Recovery does not match the planned layout.'
        }
        Format-Volume -Partition $new -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' -Force -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $targetDir = "$tmpLetter`:\Recovery\WindowsRE"
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $targetFile = Join-Path $targetDir 'Winre.wim'
    Copy-Item -LiteralPath $script:WimFile -Destination $targetFile -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $script:WimFile -Algorithm SHA256).Hash -ine (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash) {
        throw 'Copied Winre.wim failed SHA-256 verification.'
    }
    if ((Get-Volume -DriveLetter $tmpLetter).SizeRemaining -lt 250 * $script:MiB) { throw 'Fewer than 250 MiB remain after copying Winre.wim.' }
    Say 'Registering and enabling WinRE...'
    Run-External 'reagentc.exe' @('/setreimage','/path',$targetDir)
    Run-External 'reagentc.exe' @('/enable')
    $final = Get-ReInfo
    if ($final.Status -ne 'Enabled') { throw 'WinRE did not reach Enabled status.' }
    if ($final.Output -notmatch "(?i)harddisk$script:DiskNumber\\partition$script:NewPartNumber(\\|\b)") {
        throw 'WinRE is enabled but its location could not be verified. Recovery type was not changed.'
    }
    if ($plan.Mode -eq 'Rebuild') {
        Say 'Applying GPT/MBR Recovery type and attributes...'
        Set-RecoveryType $script:NewPartNumber ([string]$disk.PartitionStyle)
    }
    $final = Get-ReInfo
    if ($final.Status -ne 'Enabled' -or $final.Output -notmatch "(?i)harddisk$script:DiskNumber\\partition$script:NewPartNumber(\\|\b)") {
        throw 'Final WinRE validation failed after setting the partition type.'
    }
    Say $final.Output
    $script:Completed = $true
    Write-Result 'SUCCESS: WinRE restored and the Recovery partition configured.'
} catch {
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        # Ctrl+C may surface as a pipeline-stopped exception. The finally
        # block prints the same interruption notice as a direct pipeline stop.
    } else {
        $script:Failed = $true
        Write-Section 'ERROR'
        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ''
        if ($script:Mutated) {
            Write-Notice 'The disk may have changed. Check its layout before running again.'
        }
        Write-Host '  Diagnostics: Get-Partition; reagentc /info' -ForegroundColor Gray
    }
} finally {
    if ($script:Mounted) {
        try {
            Run-External 'dism.exe' @('/English','/Unmount-Image',"/MountDir:$script:MountDir",'/Discard')
            $script:Mounted = $false
        } catch { Write-Warning "Failed to unmount the temporary DISM image: $_" }
    }
    if ($script:TempLetter -and $null -ne $script:NewPartNumber -and $null -ne $script:DiskNumber) {
        try {
            # Remove the temporary letter even if the partition has become hidden.
            Run-DiskPart @("select disk $script:DiskNumber", "select partition $script:NewPartNumber", "remove letter=$script:TempLetter")
        } catch { Write-Warning "Failed to remove temporary drive letter $script:TempLetter`: $_" }
    }
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir -PathType Container)) {
        if ($script:Mutated -and -not $script:Completed) {
            Say "Temporary Winre.wim preserved for manual recovery: $script:WimFile"
            Say "Temporary directory: $script:WorkDir"
        } elseif (-not $script:Mounted) {
            try { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Failed to remove temporary directory: $_" }
        }
    }
    if (-not $script:Failed -and -not $script:ResultWasReported -and -not $script:SkipExitPause) {
        # Unwinding from Ctrl+C can bypass catch. No normal result was printed.
        $global:LASTEXITCODE = 130
        Write-InterruptedNotice
    } elseif ($script:Failed) {
        $global:LASTEXITCODE = 1
    }
    if (-not $script:SkipExitPause) { Wait-ForExitKey }
}

if ($script:Failed) { throw 'WinRE-Manager failed; see the error above.' }
