$ErrorActionPreference = 'Stop'
$results = @()
foreach ($mode in @('spike-overlay', 'spike-uia', 'spike-brain', 'spike-ocr')) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $originalPath = $env:PATH
    if ($mode -eq 'spike-brain') { $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'Swift' }) -join ';' }
    try {
        & ./artifacts/shell/LifeNarrator.Windows.exe $mode 2>&1 | Tee-Object "artifacts/$mode.log"
        $modeExit = $LASTEXITCODE
    } finally { $env:PATH = $originalPath }
    $results += @{ mode = $mode; exitCode = $modeExit; elapsedSeconds = $watch.Elapsed.TotalSeconds }
}
$results | ConvertTo-Json | Set-Content artifacts/modes.json
if ($results.Where({ $_.exitCode -ne 0 }).Count) { throw 'One or more spike modes failed; see artifacts' }
