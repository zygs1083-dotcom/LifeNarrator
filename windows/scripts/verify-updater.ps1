$ErrorActionPreference = 'Stop'
function Assert-JsonEqual($expected, $actual, [string]$path = '$') {
    if ($null -eq $expected -or $null -eq $actual) {
        if ($null -ne $expected -or $null -ne $actual) { throw "Update changed user settings at $path" }
        return
    }
    if ($expected.GetType() -ne $actual.GetType()) { throw "Update changed user settings type at $path" }
    if ($expected -is [System.Management.Automation.PSCustomObject]) {
        $names = @($expected.PSObject.Properties | ForEach-Object { $_.Name })
        $actualNames = @($actual.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names.Count -ne $actualNames.Count) { throw "Update changed user settings fields at $path" }
        foreach ($name in $names) {
            if ($actualNames -cnotcontains $name) { throw "Update removed user setting $path.$name" }
            Assert-JsonEqual $expected.$name $actual.$name "$path.$name"
        }
    } elseif ($expected -is [array]) {
        if ($expected.Count -ne $actual.Count) { throw "Update changed user settings array at $path" }
        for ($i = 0; $i -lt $expected.Count; $i++) {
            Assert-JsonEqual $expected[$i] $actual[$i] "$path[$i]"
        }
    } elseif ($expected -cne $actual) { throw "Update changed user settings at $path" }
}
$workspace = (Get-Location).Path
$artifacts = Join-Path $workspace 'artifacts'
$installed = Join-Path $env:LOCALAPPDATA 'Programs/LifeNarrator'
$data = Join-Path $env:APPDATA 'LifeNarrator'
$version = [regex]::Match((Get-Content Sources/NarratorCore/NarratorCore.swift -Raw), 'version = "([^"]+)"').Groups[1].Value
$service = Join-Path $artifacts 'update-service'
$release = Join-Path $service "releases/download/v$version"
New-Item $release, "$service/releases/latest/download" -ItemType Directory -Force | Out-Null
Copy-Item artifacts/LifeNarrator-Setup.exe, artifacts/checksums-windows.txt $release
$version | Set-Content "$service/releases/latest/download/version.txt" -Encoding ascii
$server = $null; $app = $null
$oldPath = $env:PATH
try {
    # Both fixtures use current source; only the baseline shell version is older.
    & windows/scripts/build-installer.ps1 -Version '0.0.1'
    $setup = Start-Process ./artifacts/LifeNarrator-Setup.exe -ArgumentList "/VERYSILENT /CURRENTUSER /SUPPRESSMSGBOXES /NORESTART /LOG=`"$artifacts/update-baseline-install.log`"" -PassThru -Wait
    if ($setup.ExitCode -ne 0) { throw "Baseline install failed: $($setup.ExitCode)" }
    if (Test-Path $data) { Remove-Item $data -Recurse -Force }
    New-Item "$data/memory" -ItemType Directory -Force | Out-Null
    @{
        onboardingCompleted = $true; launchAtLogin = $false; automaticUpdates = $true; language = 'zh'
        persona = 'cat'; paused = $true; markGap = 7; dwell = 12; maxOnScreen = 4
        provider = @{ kind = 'none' }
    } | ConvertTo-Json | Set-Content "$data/settings.json" -Encoding utf8
    '{"fixture":"user data must survive an update"}' | Set-Content "$data/memory/update-fixture.json" -Encoding utf8
    $memoryHash = (Get-FileHash "$data/memory/update-fixture.json").Hash
    $server = Start-Process python -ArgumentList @('-m', 'http.server', '18766', '--bind', '127.0.0.1', '--directory', "`"$service`"") -PassThru -RedirectStandardOutput artifacts/update-server.stdout.log -RedirectStandardError artifacts/update-server.stderr.log
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { $null = Invoke-WebRequest 'http://127.0.0.1:18766/releases/latest/download/version.txt'; $ready = $true; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (!$ready) { throw 'Update static server did not start' }
    $env:LIFENARRATOR_UPDATE_RELEASES = 'http://127.0.0.1:18766/releases/'
    $env:LIFENARRATOR_VERIFY_UPDATE_RESULT = '1'
    $env:LIFENARRATOR_UPDATE_WORKSPACE = $workspace
    $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'Swift|dotnet' }) -join ';'
    $app = Start-Process "$installed/LifeNarrator.exe" -ArgumentList '--verify-update' -PassThru -RedirectStandardOutput artifacts/update-shell.stdout.log -RedirectStandardError artifacts/update-shell.stderr.log
    if (!$app.WaitForExit(120000)) { throw 'Baseline app did not quit for update' }
    if ($app.ExitCode -ne 0) { throw "Baseline app failed: $($app.ExitCode)" }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path artifacts/update-after.json)) {
        if (Test-Path artifacts/update-failure.json) { throw (Get-Content artifacts/update-failure.json -Raw) }
        if (Test-Path "$data/updates/failure.json") { throw (Get-Content "$data/updates/failure.json" -Raw) }
        if ($watch.Elapsed.TotalSeconds -gt 120) { throw 'Updated app did not restart' }
        Start-Sleep -Milliseconds 200
    }
    $before = Get-Content artifacts/update-before.json -Raw | ConvertFrom-Json
    $after = Get-Content artifacts/update-after.json -Raw | ConvertFrom-Json
    $beforeSettings = Get-Content artifacts/update-settings-before.json -Raw | ConvertFrom-Json -Depth 100
    $afterSettings = Get-Content artifacts/update-settings-after.json -Raw | ConvertFrom-Json -Depth 100
    $settingsHash = (Get-FileHash artifacts/update-settings-after.json).Hash
    if ($before.version -ne '0.0.1' -or $after.version -ne $version -or $after.brain.version -ne $version) { throw 'Running version did not advance' }
    if ($after.executable -ne "$installed\LifeNarrator.exe" -or $after.installFailure) { throw 'Updated installed app is unhealthy' }
    if ((Get-FileHash "$installed/LifeNarrator.exe").Hash -eq (Get-FileHash artifacts/shell/LifeNarrator.exe).Hash) { throw 'Installed executable is still the old build' }
    if (Get-Process -Id $before.shellPID, $before.brainPID -ErrorAction SilentlyContinue) { throw 'Old shell or brain survived update' }
    if ($beforeSettings.seenAnnouncementVersion -cne '0.0.1' -or $afterSettings.seenAnnouncementVersion -cne $version) { throw 'Announcement read version did not advance with the installed version' }
    # Only this top-level field may change after dismissing each version's automatic announcement.
    $beforeSettings.PSObject.Properties.Remove('seenAnnouncementVersion')
    $afterSettings.PSObject.Properties.Remove('seenAnnouncementVersion')
    Assert-JsonEqual $beforeSettings $afterSettings
    $running = Get-Process -Id $after.shellPID -ErrorAction SilentlyContinue
    if ($running) {
        if (!$running.WaitForExit(30000)) { throw 'Updated verification app did not exit' }
        if ($running.ExitCode -ne 0) { throw "Updated verification app failed: $($running.ExitCode)" }
    }
    if (Test-Path artifacts/update-failure.json) { throw (Get-Content artifacts/update-failure.json -Raw) }
    if ((Get-FileHash "$data/settings.json").Hash -ne $settingsHash) { throw 'Settings changed after the updated snapshot' }
    if ((Get-FileHash "$data/memory/update-fixture.json").Hash -ne $memoryHash) { throw 'Update changed memory fixture' }
    $settings = Get-Content "$data/settings.json" -Raw | ConvertFrom-Json
    if ($settings.persona -ne 'cat' -or !$settings.paused -or $settings.markGap -ne 7 -or $settings.launchAtLogin -or !$settings.automaticUpdates) { throw 'User preferences were not preserved' }
    $watch.Restart()
    while (!(Get-ChildItem "$data/updates" -Filter update.log -Recurse | Select-String 'Installer exit code: 0')) {
        if ($watch.Elapsed.TotalSeconds -gt 30) { throw 'Installer did not report success' }
        Start-Sleep -Milliseconds 200
    }
    $log = Get-ChildItem "$data/updates" -Filter update.log -Recurse | Select-Object -First 1
    if (!(Select-String $log.FullName -Pattern 'Installer is unsigned; skipping signer comparison.' -SimpleMatch)) { throw 'Unsigned-installer decision was not logged' }
    @{ from = $before.version; to = $after.version; runningNewBrain = $true; previousProcessesExited = $true
        settingsPreserved = $true; memoryPreserved = $true; installedExecutable = $after.executable
        announcementReadBefore = $before.version; announcementReadAfter = $after.version
        settingsSHA256 = $settingsHash; memorySHA256 = $memoryHash } | ConvertTo-Json | Set-Content artifacts/update-verification.json
} finally {
    $env:PATH = $oldPath
    Remove-Item Env:LIFENARRATOR_UPDATE_RELEASES, Env:LIFENARRATOR_VERIFY_UPDATE_RESULT, Env:LIFENARRATOR_UPDATE_WORKSPACE -ErrorAction SilentlyContinue
    if (Test-Path "$data/updates") {
        New-Item artifacts/update-logs -ItemType Directory -Force | Out-Null
        Get-ChildItem "$data/updates" -Filter '*.log' -Recurse | Copy-Item -Destination artifacts/update-logs -Force
        if (Test-Path "$data/updates/failure.json") { Copy-Item "$data/updates/failure.json" artifacts/update-logs }
    }
    Copy-Item "$release/LifeNarrator-Setup.exe", "$release/checksums-windows.txt" artifacts -Force
    foreach ($owned in @($app, $server)) {
        if ($null -ne $owned -and !$owned.HasExited) { taskkill /PID $owned.Id /T /F | Out-Null }
    }
}
