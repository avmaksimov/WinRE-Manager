#Requires -Version 5.1
# WinRE-Manager installer/updater for a public GitHub repository.
# Downloads with Invoke-WebRequest, checks SHA-256, and asks for one Y/N.
# No version backups or deletion of unrelated files.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$owner = 'avmaksimov'
$repository = 'WinRE-Manager'
$branch = 'main'
$files = @('WinRE-Manager.cmd', 'WinRE-Manager.ps1', 'README.md', 'README.ru.md', 'install.ps1')
$target = (Get-Location).ProviderPath
$url = "https://github.com/$owner/$repository/archive/refs/heads/$branch.zip"
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
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'Downloaded ZIP not found.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force -ErrorAction Stop
    $roots = @(Get-ChildItem -LiteralPath $extract -Directory)
    if ($roots.Count -ne 1) { throw 'Unexpected ZIP root structure.' }
    $sourceRoot = $roots[0].FullName
    $changes = @()
    $unchangedCount = 0
    foreach ($name in $files) {
        $from = Join-Path $sourceRoot $name
        $to = Join-Path $target $name
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Missing file in ZIP: $name. No files were changed." }
        $newHash = (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
        if (-not (Test-Path -LiteralPath $to -PathType Leaf)) {
            $changes += [pscustomobject]@{ Name=$name; Source=$from; Target=$to; Hash=$newHash; State='INSTALL' }
        } elseif ((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -ine $newHash) {
            $changes += [pscustomobject]@{ Name=$name; Source=$from; Target=$to; Hash=$newHash; State='REPLACE' }
        } else {
            $unchangedCount++
        }
    }
    if ($changes.Count -eq 0) {
        Write-Host 'All files are up to date.' -ForegroundColor Green
        return
    }

    $installCount = @($changes | Where-Object { $_.State -eq 'INSTALL' }).Count
    $replaceCount = @($changes | Where-Object { $_.State -eq 'REPLACE' }).Count

    Write-Host ''
    Write-Host 'INSTALL = new file; REPLACE = existing file with different SHA-256.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '=== INSTALL/UPDATE SUMMARY ===' -ForegroundColor Cyan
    Write-Host 'Destination: ' -ForegroundColor Gray -NoNewline
    Write-Host $target -ForegroundColor White
    Write-Host ("Changes: {0} to install, {1} to replace; {2} unchanged (skipped)." -f $installCount, $replaceCount, $unchangedCount) -ForegroundColor Gray
    Write-Host ''
    foreach ($item in $changes) {
        $stateColor = if ($item.State -eq 'INSTALL') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-9}" -f $item.State) -ForegroundColor $stateColor -NoNewline
        Write-Host $item.Name -ForegroundColor White
    }
    Write-Host ''
    Write-Host 'Only the files listed above will be installed or replaced.' -ForegroundColor Gray
    Write-Host 'Other files are retained; no old-version backups are created.' -ForegroundColor Gray
    Write-Host ''
    $choice = (Read-Host 'Apply these changes? [Y/N]').Trim().ToUpperInvariant()
    if ($choice -cne 'Y') { Write-Host 'Canceled. No files were replaced.'; return }

    # Stage all updates alongside destination files before any replacement.
    foreach ($item in $changes) {
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
        if (Test-Path -LiteralPath $item.Target -PathType Leaf) {
            # Replace on the same NTFS volume, without a backup file.
            [IO.File]::Replace($staged, $item.Target, $null)
        } else {
            [IO.File]::Move($staged, $item.Target)
        }
        $verb = if ($item.State -eq 'INSTALL') { 'Installed' } else { 'Replaced' }
        Write-Host "${verb}: $($item.Name)"
    }
    Write-Host 'Update completed.'
} catch {
    $failed = $true
    Write-Host ('INSTALL ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Some files may already have been updated; inspect the output above.' -ForegroundColor Yellow
} finally {
    foreach ($path in $stagedFiles) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($failed) { exit 1 }
