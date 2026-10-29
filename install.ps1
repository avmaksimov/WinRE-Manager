#Requires -Version 5.1
# WinRE-Manager installer/updater for a public GitHub repository.
# Downloads with Invoke-WebRequest, compares SHA-256, and asks for one Y/N.
# Installs repository files (excluding any dot-prefixed files or folders), including subfolders.
# Does not delete unrelated files or create old-version backups or log files.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Explorer's "Run with PowerShell" opens a dedicated process; an existing
# PowerShell/CMD/terminal session should not be paused by this script.
function Test-ExplorerLaunch {
    try {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return $false }
        $process = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop
        if (-not $process -or $process.CommandLine -notmatch '(?i)(?:^|\s)-(?:file|command)\b') { return $false }
        $parent = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $process.ParentProcessId) -ErrorAction Stop
        return ($null -ne $parent -and $parent.Name -ieq 'explorer.exe')
    } catch {
        # An unknown launcher must never block an existing terminal.
        return $false
    }
}

function Wait-ForExitKey {
    if (-not $script:PauseAtExit) { return }
    try {
        Write-Host ''
        Write-Host 'Press any key to finish...' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    } catch {
        # Input may not be available in unusual console hosts.
    }
}

$script:PauseAtExit = Test-ExplorerLaunch
$owner = 'avmaksimov'
$repository = 'WinRE-Manager'
$branch = 'main'
$target = (Get-Location).ProviderPath
$url = "https://github.com/$owner/$repository/archive/refs/heads/$branch.zip"
$downloadUrl = $url + '?cacheBust=' + [guid]::NewGuid().ToString('N')
$noCacheHeaders = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
$tempDir = Join-Path $env:TEMP ('WinRE-Manager-Install-' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $tempDir 'source.zip'
$extract = Join-Path $tempDir 'unpacked'
$stagedFiles = New-Object 'System.Collections.Generic.List[string]'
$failed = $false

try {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Host "Source: $url"
    Write-Host "Destination: $target"
    Write-Host 'Downloading repository ZIP with Invoke-WebRequest...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $downloadUrl -Headers $noCacheHeaders -OutFile $zip -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'Downloaded ZIP not found.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force -ErrorAction Stop
    $roots = @(Get-ChildItem -LiteralPath $extract -Directory)
    if ($roots.Count -ne 1) { throw 'Unexpected ZIP root structure.' }
    $sourceRoot = $roots[0].FullName.TrimEnd('\')

    # GitHub ZIPs contain one repository-name root. Discover all files beneath
    # it instead of maintaining a hard-coded list. Preserve relative paths.
    $sourceFiles = @(
        Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop |
            Where-Object {
                $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
                # Skip any path component beginning with a dot, at any depth.
                $relative -notmatch '(?:^|[\\/])\.'
            } |
            Sort-Object { $_.FullName.Substring($sourceRoot.Length).TrimStart('\') }
    )
    if ($sourceFiles.Count -eq 0) { throw 'No installable files found in the ZIP.' }

    $entries = @()
    $changes = @()
    $unchangedCount = 0
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sourceFile in $sourceFiles) {
        if (($sourceFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsupported symbolic link in ZIP: $($sourceFile.FullName)"
        }
        $name = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\')
        if (-not $seen.Add($name)) { throw "Duplicate path in ZIP: $name" }
        $from = $sourceFile.FullName
        $to = Join-Path $target $name
        if (Test-Path -LiteralPath $to -PathType Container) {
            throw "Destination is a directory, not a file: $to"
        }
        $newHash = (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
        $state = if (-not (Test-Path -LiteralPath $to -PathType Leaf)) {
            'INSTALL'
        } elseif ((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -ine $newHash) {
            'REPLACE'
        } else {
            'UNCHANGED'
        }
        $entry = [pscustomobject]@{ Name=$name; Source=$from; Target=$to; Hash=$newHash; State=$state }
        $entries += $entry
        if ($state -eq 'UNCHANGED') { $unchangedCount++ }
        else { $changes += $entry }
    }

    if ($changes.Count -eq 0) {
        Write-Host ''
        Write-Host 'All files are up to date.' -ForegroundColor Green
        return
    }

    $installCount = @($changes | Where-Object { $_.State -eq 'INSTALL' }).Count
    $replaceCount = @($changes | Where-Object { $_.State -eq 'REPLACE' }).Count

    Write-Host ''
    Write-Host 'INSTALL = new; REPLACE = changed; UNCHANGED = identical SHA-256 (skipped).' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '=== INSTALL/UPDATE SUMMARY ===' -ForegroundColor Cyan
    Write-Host 'Destination: ' -ForegroundColor Gray -NoNewline
    Write-Host $target -ForegroundColor White
    Write-Host ("Changes: {0} to install, {1} to replace; {2} unchanged (skipped)." -f $installCount, $replaceCount, $unchangedCount) -ForegroundColor Gray
    Write-Host ''
    foreach ($item in $entries) {
        $stateColor = switch ($item.State) {
            'INSTALL' { 'Green' }
            'REPLACE' { 'Yellow' }
            default { 'DarkGray' }
        }
        Write-Host ("  {0,-11}" -f $item.State) -ForegroundColor $stateColor -NoNewline
        $nameColor = if ($item.State -eq 'UNCHANGED') { 'DarkGray' } else { 'White' }
        Write-Host $item.Name -ForegroundColor $nameColor
    }
    Write-Host ''
    Write-Host 'Only INSTALL and REPLACE files will be changed.' -ForegroundColor Gray
    Write-Host 'Other files are retained; no old-version backups are created.' -ForegroundColor Gray
    Write-Host ''
    $choice = (Read-Host 'Apply these changes? [Y/N]').Trim().ToUpperInvariant()
    if ($choice -cne 'Y') {
        Write-Host ''
        Write-Host 'Canceled. No files were replaced.'
        return
    }

    # Stage all updates beside their final destinations, before replacing any.
    foreach ($item in $changes) {
        $parentDir = Split-Path -Path $item.Target -Parent
        if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
            New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
        }
        $staged = $item.Target + '.new'
        if (Test-Path -LiteralPath $staged) { throw "Temporary destination already exists: $staged" }
        Copy-Item -LiteralPath $item.Source -Destination $staged -ErrorAction Stop
        $stagedFiles.Add($staged)
        if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ine $item.Hash) {
            throw "SHA-256 mismatch for $staged; originals were not touched."
        }
    }
    foreach ($item in $changes) {
        $staged = $item.Target + '.new'
        Move-Item -LiteralPath $staged -Destination $item.Target -Force -ErrorAction Stop
        $verb = if ($item.State -eq 'INSTALL') { 'Installed' } else { 'Replaced' }
        Write-Host "${verb}: $($item.Name)" -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'Update completed.'
} catch {
    $failed = $true
    Write-Host ''
    Write-Host ('INSTALL ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Some files may already have been updated; inspect the output above.' -ForegroundColor Yellow
} finally {
    foreach ($path in $stagedFiles) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Wait-ForExitKey
}
if ($failed) { throw 'Installer failed; see the error above.' }
