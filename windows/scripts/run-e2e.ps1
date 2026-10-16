$ErrorActionPreference = 'Stop'
$data = Join-Path $env:APPDATA 'LifeNarrator'
New-Item -ItemType Directory -Force $data | Out-Null
Copy-Item artifacts/brain artifacts/shell/brain -Recurse
@{
    onboardingCompleted = $true; launchAtLogin = $false; language = 'zh'; liveliness = 'lively'; persona = 'gentle'; lang = 'zh'; paused = $false
    markGap = 1; dwell = 60; maxOnScreen = 3; blacklist = @()
    provider = @{ kind = 'api'; presetId = 'custom-openai'; model = 'ci-stub'; baseURL = 'http://127.0.0.1:18765/v1'; structured = 'json_object' }
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $data 'settings.json') -Encoding utf8
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class E2EWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Mouse {
        public int x, y; public uint data, flags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Keyboard {
        public ushort key, scan; public uint flags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Explicit, Size=40)] public struct Input {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public Mouse mouse;
        [FieldOffset(8)] public Keyboard keyboard;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(IntPtr cls, string title);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, Input[] inputs, int size);
    public static void ActiveMouse() {
        var right = new Input { mouse = new Mouse { x = 1, flags = 1 } };
        var left = new Input { mouse = new Mouse { x = -1, flags = 1 } };
        if (SendInput(2, new[] { right, left }, 40) != 2) throw new Exception("SendInput mouse failed");
    }
    public static void Click() {
        var down = new Input { mouse = new Mouse { flags = 2 } };
        var up = new Input { mouse = new Mouse { flags = 4 } };
        if (SendInput(2, new[] { down, up }, 40) != 2) throw new Exception("SendInput click failed");
    }
    public static void Wheel(int delta) {
        var input = new Input { mouse = new Mouse { data = unchecked((uint)delta), flags = 0x800 } };
        if (SendInput(1, new[] { input }, 40) != 1) throw new Exception("SendInput wheel failed");
    }
    public static void PageDown() {
        var down = new Input { type = 1, keyboard = new Keyboard { key = 0x22 } };
        var up = new Input { type = 1, keyboard = new Keyboard { key = 0x22, flags = 2 } };
        if (SendInput(2, new[] { down, up }, 40) != 2) throw new Exception("SendInput key failed");
    }
}
'@
function Screenshot($name) {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save((Join-Path (Resolve-Path artifacts).Path $name))
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Wait-For($description, [scriptblock]$condition) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 90) {
        if ($script:shell -and $script:shell.HasExited) { throw "Shell exited: $($script:shell.ExitCode)" }
        if (& $condition) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out: $description"
}
function Overlay-Records($path) {
    if (Test-Path $path) {
        Get-Content $path | Where-Object { $_.StartsWith('[overlay] ') } |
            ForEach-Object { $_.Substring(10) | ConvertFrom-Json }
    }
}
function Probe($name) {
    $probe = Start-Process ./artifacts/shell/LifeNarrator.exe -ArgumentList '--spike', 'follow-probe' -Wait -PassThru -NoNewWindow -RedirectStandardOutput artifacts/e2e-probe.stdout.log -RedirectStandardError artifacts/e2e-probe.stderr.log
    if ($probe.ExitCode -ne 0) { throw "Independent UIA probe failed: $($probe.ExitCode)" }
    Copy-Item artifacts/e2e-probe.json "artifacts/e2e-$name-text.json"
    return (Get-Content artifacts/e2e-probe.json -Raw | ConvertFrom-Json).rect
}
function Assert-Aligned($anchor, $text) {
    if ([Math]::Abs(($anchor.x + 5) - $text.x) -gt 3 -or
        [Math]::Abs(($anchor.y + 3) - $text.y) -gt 3 -or
        [Math]::Abs(($anchor.w - 10) - $text.w) -gt 3 -or
        [Math]::Abs(($anchor.h - 6) - $text.h) -gt 3) { throw 'Highlight does not enclose the independent UIA quote rectangle' }
}
function Assert-Pink($name, $anchor) {
    $bitmap = [System.Drawing.Bitmap]::new((Join-Path (Resolve-Path artifacts).Path $name))
    $pink = 0
    try {
        for ($y = [Math]::Max(0, [int]$anchor.y - 3); $y -le [Math]::Min($bitmap.Height - 1, [int]($anchor.y + $anchor.h) + 3); $y++) {
            for ($x = [Math]::Max(0, [int]$anchor.x - 3); $x -le [Math]::Min($bitmap.Width - 1, [int]($anchor.x + $anchor.w) + 3); $x++) {
                $p = $bitmap.GetPixel($x, $y)
                if ($p.R -gt 180 -and $p.B -gt 120 -and $p.G -lt 160 -and $p.R -gt $p.G * 1.3) { $pink++ }
            }
        }
    } finally { $bitmap.Dispose() }
    if ($pink -lt 30) { throw "No painted highlight at recorded anchor in $name (pink=$pink)" }
}
$stub = $null; $edgeProcess = $null; $shell = $null; $ocrProcess = $null
$oldDebug = $env:LIFENARRATOR_DEBUG
$oldPath = $env:PATH
try {
    $stub = Start-Process python -ArgumentList 'windows/scripts/stub-openai.py' -PassThru -RedirectStandardOutput artifacts/stub.stdout.log -RedirectStandardError artifacts/stub.stderr.log
    Wait-For 'SSE stub' { try { $null = Invoke-WebRequest http://127.0.0.1:18765/ -UseBasicParsing; $true } catch { $false } }
    $edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'
    $html = Join-Path (Resolve-Path artifacts/fixtures).Path 'e2e-follow.html'
    @'
<!doctype html><html lang="en"><meta charset="utf-8"><title>LifeNarrator follow fixture</title>
<body style="margin:40px;font:24px/40px sans-serif;height:5000px">
<p style="margin-top:300px">LifeNarrator visible English paragraph</p>
<p>Second visible line for accessibility</p><p>Third visible line for accessibility</p>
</body></html>
'@ | Set-Content $html -Encoding utf8
    $profile = Join-Path (Resolve-Path artifacts/fixtures).Path 'e2e-edge-profile'
    $edgeProcess = Start-Process $edge -ArgumentList @("--user-data-dir=`"$profile`"", '--force-renderer-accessibility', '--no-first-run', '--no-default-browser-check', '--start-maximized', '--new-window', ([uri]$html).AbsoluteUri) -PassThru
    Wait-For 'Edge fixture window' { @(Get-Process msedge | Where-Object { $_.MainWindowTitle -like '*LifeNarrator follow fixture*' }).Count -gt 0 }
    $window = Get-Process msedge | Where-Object { $_.MainWindowTitle -like '*LifeNarrator follow fixture*' } | Select-Object -First 1
    if (![E2EWindow]::SetForegroundWindow($window.MainWindowHandle)) { throw 'Cannot foreground Edge fixture' }
    [E2EWindow]::SetCursorPos(700, 500) | Out-Null
    [E2EWindow]::Click()
    Start-Sleep -Seconds 2
    $env:LIFENARRATOR_DEBUG = '1'
    $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'Swift' }) -join ';'
    Remove-Item (Join-Path $data 'said.json'), (Join-Path $data 'brain.log') -ErrorAction SilentlyContinue
    $shell = Start-Process ./artifacts/shell/LifeNarrator.exe -PassThru -RedirectStandardOutput artifacts/shell.stdout.log -RedirectStandardError artifacts/shell.stderr.log
    Wait-For 'tracked model mark' {
        [E2EWindow]::ActiveMouse()
        @(Overlay-Records artifacts/shell.stderr.log | Where-Object { $_.action -eq 'show' -and $_.trackID -and $_.anchor }).Count -gt 0 -and
        (Test-Path (Join-Path $data 'brain.log')) -and
        (Select-String -Path (Join-Path $data 'brain.log') -Pattern 'source=model.*show=true' -Quiet)
    }
    $before = Overlay-Records artifacts/shell.stderr.log | Where-Object { $_.action -eq 'show' -and $_.trackID -and $_.anchor } | Select-Object -Last 1
    $textBefore = Probe 'before'
    Assert-Aligned $before.anchor $textBefore
    Start-Sleep -Milliseconds 250
    Screenshot 'e2e-before.png'
    Assert-Pink 'e2e-before.png' $before.anchor
    [E2EWindow]::Wheel(-120)
    Wait-For 'scroll-follow movement' { @(Overlay-Records artifacts/shell.stderr.log | Where-Object { $_.action -eq 'follow' -and $_.id -eq $before.id }).Count -gt 0 }
    Start-Sleep -Milliseconds 1200
    $after = Overlay-Records artifacts/shell.stderr.log | Where-Object { $_.action -eq 'follow' -and $_.id -eq $before.id } | Select-Object -Last 1
    $textAfter = Probe 'after'
    Assert-Aligned $after.anchor $textAfter
    Screenshot 'e2e-after.png'
    Assert-Pink 'e2e-after.png' $after.anchor
    $textDelta = $textAfter.y - $textBefore.y
    $anchorDelta = $after.anchor.y - $before.anchor.y
    if ($textDelta -ge -10 -or [Math]::Abs($textDelta - $anchorDelta) -gt 3) { throw "Highlight drift: text=$textDelta anchor=$anchorDelta" }
    if ([Math]::Abs(($after.frame.y - $before.frame.y) - $textDelta) -gt 3) { throw 'Bubble did not translate with the highlight' }
    [E2EWindow]::PageDown()
    Wait-For 'offscreen mark removal' { @(Overlay-Records artifacts/shell.stderr.log | Where-Object { $_.action -eq 'leave' -and $_.id -eq $before.id }).Count -gt 0 }
    Start-Sleep -Milliseconds 250
    Screenshot 'e2e-offscreen.png'
    # Opening the app again while it runs must bring up its settings, since the tray icon is often hidden.
    Start-Process ./artifacts/shell/LifeNarrator.exe -Wait
    Wait-For 'settings from a second launch' {
        $titles = "LifeNarrator $([char]0xB7) Settings$([char]0x2026)", "$([char]0x4EBA)$([char]0x751F)$([char]0x65C1)$([char]0x767D) $([char]0xB7) $([char]0x8BBE)$([char]0x7F6E)$([char]0x2026)"
        @($titles | Where-Object { [E2EWindow]::FindWindow([IntPtr]::Zero, $_) -ne [IntPtr]::Zero }).Count -gt 0
    }
    Screenshot 'e2e-reopen-settings.png'
    taskkill /PID $shell.Id /T /F | Out-Null
    $shell.WaitForExit(); $shell = $null
    Copy-Item (Join-Path $data 'brain.log') artifacts/e2e-follow-brain.log

    $ocrProcess = Start-Process powershell -ArgumentList '-NoProfile', '-File', 'windows/scripts/ocr-fixture.ps1' -PassThru -RedirectStandardOutput artifacts/e2e-ocr-fixture.stdout.log -RedirectStandardError artifacts/e2e-ocr-fixture.stderr.log
    Wait-For 'image-only fixture' { [E2EWindow]::FindWindow([IntPtr]::Zero, 'LifeNarrator OCR image fixture') -ne [IntPtr]::Zero }
    $ocrWindow = [E2EWindow]::FindWindow([IntPtr]::Zero, 'LifeNarrator OCR image fixture')
    if (![E2EWindow]::SetForegroundWindow($ocrWindow)) { throw 'Cannot foreground OCR fixture' }
    Start-Sleep -Seconds 2
    Remove-Item (Join-Path $data 'said.json'), (Join-Path $data 'brain.log') -ErrorAction SilentlyContinue
    $shell = Start-Process ./artifacts/shell/LifeNarrator.exe -PassThru -RedirectStandardOutput artifacts/e2e-ocr.stdout.log -RedirectStandardError artifacts/e2e-ocr.stderr.log
    Wait-For 'OCR snapshot and model mark' {
        [E2EWindow]::ActiveMouse()
        (Select-String artifacts/e2e-ocr.stderr.log -Pattern '\[sensor\] snapshot source=ocr' -Quiet) -and
        (Select-String artifacts/e2e-ocr.stderr.log -Pattern 'textRect kind=ocr' -Quiet) -and
        @(Overlay-Records artifacts/e2e-ocr.stderr.log | Where-Object { $_.action -eq 'show' -and !$_.trackID -and $_.anchor }).Count -gt 0
    }
    Start-Sleep -Milliseconds 300
    $ocrMark = Overlay-Records artifacts/e2e-ocr.stderr.log | Where-Object { $_.action -eq 'show' -and $_.anchor } | Select-Object -Last 1
    Screenshot 'e2e-ocr.png'
    Assert-Pink 'e2e-ocr.png' $ocrMark.anchor
    @{ scroll = @{ before = $before; after = $after; textBefore = $textBefore; textAfter = $textAfter; offscreenRemoved = $true }
       ocr = @{ snapshot = $true; mark = $ocrMark }; screenshots = @('e2e-before.png', 'e2e-after.png', 'e2e-offscreen.png', 'e2e-ocr.png') } |
        ConvertTo-Json -Depth 10 | Set-Content artifacts/e2e.json
    taskkill /PID $shell.Id /T /F | Out-Null
    $shell.WaitForExit(); $shell = $null
    # Use the image fixture again for the companion scene, after the follow/OCR assertions finish.
    $settings = Get-Content (Join-Path $data 'settings.json') -Raw | ConvertFrom-Json
    $settings | Add-Member -NotePropertyName bubbleShape -NotePropertyValue 'star' -Force
    $settings | Add-Member -NotePropertyName bubbleTheme -NotePropertyValue 'starry' -Force
    $settings | Add-Member -NotePropertyName memoryEnabled -NotePropertyValue $true -Force
    $settings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $data 'settings.json') -Encoding utf8
    $referenceNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 978307200
    @{
        firstMetAt = $referenceNow - 30 * 86400; activeDays = 30; consecutiveDays = 7
        narrations = 250; chatMessages = 28; rulesLearned = 0; personasTried = @('gentle')
        experience = 9100; level = 15
        unlocked = @('spriteName', 'emoji', 'starBubble', 'catchphrase', 'greetings', 'starryTheme')
        lastActiveDay = $null; narrationExperienceToday = 0; lastLateNight = $null
        anniversaries = @(7, 30); anniversaryEpisodes = @(7, 30)
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $data 'growth.json') -Encoding utf8
    Remove-Item (Join-Path $data 'memory.json'), (Join-Path $data 'chat.json'), (Join-Path $data 'sprite-name.json'),
        (Join-Path $data 'said.json'), (Join-Path $data 'brain.log'), artifacts/e2e-companion.json -ErrorAction SilentlyContinue
    if (![E2EWindow]::SetForegroundWindow($ocrWindow)) { throw 'Cannot foreground companion fixture' }
    $shell = Start-Process ./artifacts/shell/LifeNarrator.exe -ArgumentList '--verify-companion' -PassThru -RedirectStandardOutput artifacts/e2e-companion-shell.stdout.log -RedirectStandardError artifacts/e2e-companion-shell.stderr.log
    $companionWatch = [Diagnostics.Stopwatch]::StartNew()
    while (!$shell.HasExited -and $companionWatch.Elapsed.TotalSeconds -lt 90) {
        [E2EWindow]::ActiveMouse()
        Start-Sleep -Milliseconds 200
    }
    if (!$shell.HasExited) { throw 'Companion verification timed out' }
    if ($shell.ExitCode -ne 0 -or !(Test-Path artifacts/e2e-companion.json)) { throw 'Companion verification failed' }
} catch {
    Screenshot 'e2e-failure.png'
    throw
} finally {
    $env:LIFENARRATOR_DEBUG = $oldDebug
    $env:PATH = $oldPath
    if (Test-Path (Join-Path $data 'brain.log')) { Copy-Item (Join-Path $data 'brain.log') artifacts/e2e-brain.log }
    foreach ($owned in @($shell, $edgeProcess, $ocrProcess, $stub)) {
        if ($null -ne $owned -and !$owned.HasExited) { taskkill /PID $owned.Id /T /F | Out-Null }
    }
}
