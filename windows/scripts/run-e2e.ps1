$ErrorActionPreference = 'Stop'
$data = Join-Path $env:APPDATA 'LifeNarrator'
New-Item -ItemType Directory -Force $data | Out-Null
Copy-Item artifacts/brain artifacts/shell/brain -Recurse
@{
    liveliness = 'lively'; persona = 'gentle'; lang = 'zh'; paused = $false
    markGap = 1; dwell = 30; maxOnScreen = 3; blacklist = @()
    provider = @{ kind = 'api'; presetId = 'custom-openai'; model = 'ci-stub'; baseURL = 'http://127.0.0.1:18765/v1'; structured = 'json_object' }
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $data 'settings.json') -Encoding utf8
Remove-Item (Join-Path $data 'said.json'), (Join-Path $data 'brain.log') -ErrorAction SilentlyContinue
$stub = $null
$edgeProcess = $null
$shell = $null
$oldDebug = $env:LIFENARRATOR_DEBUG
$oldPath = $env:PATH
try {
    $stub = Start-Process python -ArgumentList 'windows/scripts/stub-openai.py' -PassThru -RedirectStandardOutput artifacts/stub.stdout.log -RedirectStandardError artifacts/stub.stderr.log
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { $null = Invoke-WebRequest http://127.0.0.1:18765/ -UseBasicParsing; $ready = $true; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (!$ready) { throw 'Stub did not start' }
    $edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'
    $html = (Resolve-Path artifacts/fixtures/T19-edge.html).Path
    $profile = Join-Path (Resolve-Path artifacts/fixtures).Path 'e2e-edge-profile'
    $edgeProcess = Start-Process $edge -ArgumentList @("--user-data-dir=`"$profile`"", '--force-renderer-accessibility', '--no-first-run', '--no-default-browser-check', '--start-maximized', '--new-window', ([uri]$html).AbsoluteUri) -PassThru
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class E2EWindow {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
    $window = $null
    for ($i = 0; $i -lt 100; $i++) {
        $window = Get-Process msedge | Where-Object { $_.MainWindowTitle -like '*T19 Edge fixture*' } | Select-Object -First 1
        if ($window) { break }
        Start-Sleep -Milliseconds 200
    }
    if (!$window) { throw 'Edge fixture did not open' }
    if (![E2EWindow]::SetForegroundWindow($window.MainWindowHandle)) { throw 'Cannot foreground Edge fixture' }
    Start-Sleep -Seconds 2
    $env:LIFENARRATOR_DEBUG = '1'
    $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'Swift' }) -join ';'
    $shell = Start-Process ./artifacts/shell/LifeNarrator.exe -PassThru -RedirectStandardOutput artifacts/shell.stdout.log -RedirectStandardError artifacts/shell.stderr.log
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $shown = $false
    while ($watch.Elapsed.TotalSeconds -lt 90) {
        if ($shell.HasExited) { throw "Shell exited: $($shell.ExitCode)" }
        $log = Join-Path $data 'brain.log'
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'source=model.*show=true' -Quiet)) { $shown = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if (!$shown) { throw 'Timed out waiting for brain source=model show=true' }
    Start-Sleep -Milliseconds 800
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save((Join-Path (Resolve-Path artifacts).Path 'e2e-overlay.png'))
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    @{ shown = $true; elapsedSeconds = $watch.Elapsed.TotalSeconds; screenshot = 'e2e-overlay.png' } |
        ConvertTo-Json | Set-Content artifacts/e2e.json
} finally {
    $env:LIFENARRATOR_DEBUG = $oldDebug
    $env:PATH = $oldPath
    if (Test-Path (Join-Path $data 'brain.log')) { Copy-Item (Join-Path $data 'brain.log') artifacts/e2e-brain.log }
    foreach ($owned in @($shell, $edgeProcess, $stub)) {
        if ($null -ne $owned -and !$owned.HasExited) { taskkill /PID $owned.Id /T /F | Out-Null }
    }
}
