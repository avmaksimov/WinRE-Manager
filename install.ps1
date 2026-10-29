#Requires -Version 5.1
# WinRE-Manager installer/updater for a public GitHub repository.
# Downloads with Invoke-WebRequest, checks SHA-256, and asks for one Y/N.
# No version backups or deletion of unrelated files.

# Keep the result visible when the script is launched in its own PowerShell window.
function Wait-ForExitKey {
    try {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return }
        Write-Host ''
        Write-Host 'Press any key to close...' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    } catch {
        # No interactive console (for example, a redirected or unattended run).
    }
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$owner = 'avmaksimov'
$repository = 'WinRE-Manager'
$branch = 'main'
$files = @('WinRE-Manager.cmd', 'WinRE-Manager.ps1', 'README.md', 'README.ru.md', 'install.ps1') | Sort-Object
$target = (Get-Location).ProviderPath
$url = "https://github.com/$owner/$repository/archive/refs/heads/$branch.zip"
# A unique URL and no-cache headers prevent stale repository archives from intermediary caches.
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
    $sourceRoot = $roots[0].FullName
    $entries = @()
    $changes = @()
    $unchangedCount = 0
    foreach ($name in $files) {
        $from = Join-Path $sourceRoot $name
        $to = Join-Path $target $name
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Missing file in ZIP: $name. No files were changed." }
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
    # The .new file is already in the target directory. Move-Item -Force
    # replaces an existing file without a separate backup file or Win32 interop.
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
if ($failed) { exit 1 }
