$ErrorActionPreference = 'Stop'
$installed = Join-Path $env:LOCALAPPDATA 'Programs/LifeNarrator'
$data = Join-Path $env:APPDATA 'LifeNarrator'
# The hosted runner contains only the fixtures created by run-e2e.ps1.
if (Test-Path $data) { Remove-Item $data -Recurse -Force }
$setup = Start-Process ./artifacts/LifeNarrator-Setup.exe -ArgumentList '/VERYSILENT /CURRENTUSER /SUPPRESSMSGBOXES /NORESTART /LOG=artifacts/install.log' -PassThru -Wait
if ($setup.ExitCode -ne 0) { throw "Install failed: $($setup.ExitCode)" }
if (!(Test-Path "$installed/brain/narrator-brain.exe")) { throw 'Installed brain missing' }
$stub = $null
$app = $null
$oldPath = $env:PATH
try {
    $stub = Start-Process python -ArgumentList 'windows/scripts/stub-openai.py' -PassThru -RedirectStandardOutput artifacts/installer-stub.stdout.log -RedirectStandardError artifacts/installer-stub.stderr.log
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { $null = Invoke-WebRequest http://127.0.0.1:18765/ -UseBasicParsing; $ready = $true; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (!$ready) { throw 'Stub did not start' }
    $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'Swift|dotnet' }) -join ';'
    $app = Start-Process "$installed/LifeNarrator.exe" -ArgumentList '--verify-ui' -PassThru -RedirectStandardOutput artifacts/installer-shell.stdout.log -RedirectStandardError artifacts/installer-shell.stderr.log
    if (!$app.WaitForExit(120000)) { throw 'Installed app verification timed out' }
    if ($app.ExitCode -ne 0) { throw "Installed app verification failed: $($app.ExitCode)" }
    $startup = Get-ItemPropertyValue 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run' LifeNarrator
    if ($startup -ne "`"$installed\LifeNarrator.exe`"") { throw "Wrong startup path: $startup" }
    $before = (Get-FileHash "$data/settings.json").Hash
    $uninstall = Start-Process "$installed/unins000.exe" -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=artifacts/uninstall.log' -PassThru -Wait
    if ($uninstall.ExitCode -ne 0) { throw "Uninstall failed: $($uninstall.ExitCode)" }
    if (Test-Path "$installed/LifeNarrator.exe") { throw 'Uninstall left executable behind' }
    if ((Get-FileHash "$data/settings.json").Hash -ne $before) { throw 'Silent uninstall changed user settings' }
    if (Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run' -Name LifeNarrator -ErrorAction SilentlyContinue) { throw 'Uninstall left startup entry behind' }
    @{ installed = $true; appVerified = $true; uninstalled = $true; userDataPreserved = $true } |
        ConvertTo-Json | Set-Content artifacts/installer-verification.json
} finally {
    $env:PATH = $oldPath
    foreach ($owned in @($app, $stub)) {
        if ($null -ne $owned -and !$owned.HasExited) { taskkill /PID $owned.Id /T /F | Out-Null }
    }
}
