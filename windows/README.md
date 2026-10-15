# Windows shell

`LifeNarrator.exe` is a single-instance .NET 8 / Avalonia tray application. It owns
`brain/narrator-brain.exe` and communicates over the bidirectional protocol below.
The tray provides pause, liveliness, seven built-in personas, and exit. A brain
failure turns the icon red, exposes the last six stderr lines in the menu, and
enables **重启大脑**. Restart is manual. Right-click the tray icon to open Settings.
First launch opens the welcome flow; API and offline modes are available, while the
built-in model is marked coming soon. Settings use the Mac peach-pink tokens, cards
and choice cards, with system light/dark mode and system/Chinese/English language.

Settings live in `%APPDATA%\LifeNarrator\settings.json`, alongside brain data and
`brain.log`. First launch writes the offline defaults. An API configuration is:

```json
{
  "liveliness": "lively", "persona": "gentle", "lang": "zh", "paused": false,
  "markGap": 2, "dwell": 3, "maxOnScreen": 3, "blacklist": [],
  "provider": {
    "kind": "api", "presetId": "custom-openai", "model": "your-model",
    "baseURL": "http://localhost:8080/v1", "structured": "json_object"
  }
}
```

`provider.kind` is `none` or `api`; preset IDs come from the shared provider catalog.
Keys are generic Windows credentials named `LifeNarrator/<presetId>`, stored by
`CredentialStore.Write` / read by `CredentialStore.Read`; they never enter settings.
Use the Models tab to select a grouped provider, enter the model and save its key
to Credential Manager. Advanced settings accept a base URL (including the API path
prefix) and structured-output mode. Test Connection sends a minimal request through
the brain, validates its JSON response and reports elapsed milliseconds. Edits save
and configure the running brain immediately; invalid drafts display the RPC error.
Launch at login is enabled by default via the current user Run registry key.

UIA lives on a dedicated MTA thread with a 4000-element control-view traversal.
Foreground/location WinEvents, low-level keyboard/mouse hooks, and a 3-second
active-user poll drive snapshots. Visible TextPattern ranges are split by line;
subranges use UIA bounds or explicitly tagged proportional estimates. Text anchors
retain their UIA element/range on that thread. Wheel, navigation-key,
and ScrollPattern notifications drive at most 60 follow reads per second until one
second after the last event. Follow reads set UIA connection/transaction timeouts
to 100 ms;
expired elements and offscreen anchors lose their decoration immediately and the
narration fades out. OCR anchors are dismissed on wheel/ScrollPattern events.

Fewer than three visible UIA text lines trigger in-memory `PrintWindow` capture
(`PW_RENDERFULLCONTENT`) and Windows OCR (Simplified Chinese, then en-US). A reduced
image hash avoids recognizing unchanged frames; OCR ranges use word rectangles.
If neither language is installed the tray explains how to install one. Production
captures never touch disk. Each monitor has a transparent, topmost, click-through,
nonactivating overlay. The brain owns size-tier and placement calculations.

Coordinates retain a monitor's physical origin and divide distances from that
origin by its scale. All geometry in one snapshot/layout uses that monitor's map;
the overlay maps local logical distances back through Avalonia's render scale.
Negative monitor origins are preserved. Moving between monitor maps dismisses old
marks and captures a new snapshot. Monitor configuration is captured on startup;
restart after changing the display topology/scaling. Mixed-DPI and real UIA
coverage still require Windows hardware checks.

## Build and verify

```sh
swift test
dotnet build windows/LifeNarrator.Windows -c Release
dotnet run --project windows/LifeNarrator.HeadlessTests -c Release -- .build/debug/narrator-brain
```

On Windows, after packaging and publishing as below, copy `artifacts/brain` into
`artifacts/shell/brain` to run the app. CI's `run-e2e.ps1` does this automatically,
starts the loopback SSE stub, presets API settings, opens a long Edge fixture, and
requires a tracked model mark within 90 seconds. It sends a wheel event and
compares the independent UIA text displacement against the highlight and bubble
(to within 3 physical pixels), verifies painted pink pixels, then uses PageDown to
verify removal. An image-only WinForms window must produce an OCR snapshot,
word-based `textRect`, and a painted mark. It saves `e2e-before.png`,
`e2e-after.png`, `e2e-offscreen.png`, `e2e-ocr.png`, geometry JSON and logs in the
`windows-shell-e2e` and `windows-spike` artifacts. The protocol checks exercise
concurrent requests and
nested layout calls against the actual packaged brain before GUI verification.

## Retained T19 spike harness

The full T20b brain and W1 layout/port contract is in [brain-protocol.md](brain-protocol.md).
The standalone T19 `ping` / `matchRules` harness below remains supported.

The shared Swift core stays in-process on macOS. The four T19 modes are retained
under `LifeNarrator.exe --spike overlay|uia|brain|ocr`; they do not start the tray.

## Run

```sh
swift test
# Linux, .NET 8 SDK and system CJK/emoji fonts:
dotnet run --project windows/LifeNarrator.HeadlessTests -c Release
```

On Windows, CI builds `narrator-brain` in Release, resolves its PE import closure with `dumpbin`, copies its resource bundles into `artifacts/brain`, and publishes a self-contained .NET 8 shell into `artifacts/shell`. From the repository root:

```powershell
windows/scripts/package-brain.ps1
dotnet publish windows/LifeNarrator.Windows -c Release -r win-x64 --self-contained true -o artifacts/shell
windows/scripts/run-spikes.ps1
```

The four modes run in order: overlay screenshot/styles, Notepad and Edge UIA, brain round trip, OCR of the overlay screenshot. Each mode writes JSON and the script saves its console log and duration. `brain-size.json` lists the executable and runtime files; `shell-size.json` records the self-contained publication size. CI uploads all of `artifacts/` as `windows-spike` and the Linux rendering as `windows-bubble-headless`.

UIA uses **Interop.UIAutomationClient**, the direct COM declarations for the operating system's UIA3 API. This spike only needs element properties and TextPattern; FlaUI's additional wrapper layer is unnecessary. Avalonia 11.3.10 and the permitted UIA interop package are the only direct package dependencies (the headless project also uses Avalonia.Headless and Avalonia.Skia).

The headless test is a standalone executable with pixel assertions and a nonzero failure exit code, avoiding an additional test framework dependency. It shares the exact `BubbleSample` source with the Windows shell.

## Stdio contract

One UTF-8 JSON-RPC 2.0 object per line. Output contains protocol responses only; EOF shuts down the process. Notifications do not produce a response. JSON-RPC parse, invalid request, unknown method and invalid params errors use `-32700`, `-32600`, `-32601` and `-32602` respectively. Batch requests are outside this line protocol.

- `ping` returns `{ "version": NarratorCore.version }`.
- `matchRules` takes `{ "snapshot": ContextSnapshot, "rules": [Rule] }` using the existing Codable fields. Dates are ISO 8601; CGRect is `[[x,y],[width,height]]`. It validates rules at the IPC boundary and returns `[{ "ruleId": "...", "lineIndex": 0 }]` in RuleMatcher's candidate order. `lineIndex` is zero based; a window-title/app/site/time match has `null`. The snapshot is treated as a context change (`appChanged` and `hostChanged` true); matching time is `snapshot.capturedAt`, so the handler is deterministic.

The standalone spike does not start the tray application. The full shell uses
the configure/event/port contract in brain-protocol.md.

## Evidence interpretation

- `overlay.json` reports the actual Win32 extended styles, actual Avalonia transparency level and foreground handle before/after showing the overlay. The runner uses software rendering and a redirection surface without relying on a GPU. Win32Properties.AddWindowStylesCallback preserves the custom flags when Avalonia recomputes window styles; SetLayeredWindowAttributes enables the layered window after showing it.
- `uia.json` preserves every visible named element and TextPattern visible range with physical screen rectangles and control type/role. ValuePattern is recorded separately as a full-value/edit-control rectangle, never as a visible line range; classic Notepad on the runner lacks TextPattern. Each fixture reports whether both known Chinese and English body strings were found, and whether their rectangles lie inside its window. Screenshots `uia-notepad.png` and `uia-edge.png` allow visual comparison. This bounds check alone does not establish glyph-level accuracy or mixed-DPI behavior. Edge is launched with `--force-renderer-accessibility` and a disposable profile; the result must not be generalized to every existing Chromium session.
- `brain.json` preserves requests, responses, elapsed milliseconds, exit code and stderr. The runner removes installed Swift directories from PATH for this mode, so the process must use the packaged runtime.
- `ocr.json` reports installed OCR languages, the selected language, text, word rectangles and source image dimensions. Chinese OCR requires an installed Chinese language pack. English-only recognition cannot establish Chinese OCR quality.

API references: [Avalonia headless rendering](https://docs.avaloniaui.net/docs/testing/setting-up-the-headless-platform), [UIA text ranges](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-usingtextrangeobjects), [extended window styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles), [Windows.Media.Ocr](https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrengine).

## Installer

CI installs Inno Setup with Chocolatey, runs `windows/scripts/build-installer.ps1`,
and uploads `LifeNarrator-Setup.exe` plus `checksums-windows.txt` in the
`LifeNarrator-Windows` artifact. Release tags upload the same files to the macOS
Release. Installation is per user in `%LOCALAPPDATA%\Programs\LifeNarrator`,
with a Start menu shortcut and an optional launch step; no administrator is needed.
The unsigned preview may require **More info → Run anyway** in SmartScreen.

`windows/scripts/verify-installer.ps1` silently installs with `/VERYSILENT /CURRENTUSER`,
runs the installed app's `--verify-ui` harness without SDK directories in PATH,
checks offline onboarding, a persona/timing edit, Credential Manager and a real
brain connection test against the loopback fixture, then captures the three tabs
in Chinese/light and English/dark plus the actual tray menu. It silently uninstalls
and asserts user settings survived and the Run entry was removed. Screenshots and
JSON/log evidence are in `LifeNarrator-Windows`. This verification flag is intended
only for the disposable CI runner and writes fixture settings and credentials.

Interactive uninstall asks whether to delete settings, local history and API keys.
No is the default. Silent uninstall always retains user data and credentials.

## 内置 GGUF 引擎（W2b）

Windows x64 构建前运行 `windows/scripts/setup-llama.ps1`。脚本校验官方 b11429 CPU / Vulkan ZIP 和同提交 C 头文件的 SHA-256，解压到 gitignore 的 `.dev-data/llama`，从 DLL 导出表生成 MSVC 导入库；`windows/llama/module.modulemap` 供 SwiftPM 导入。脚本把运行库目录加入当前 PowerShell 的 PATH；手动开发时用 `. windows/scripts/setup-llama.ps1` 后运行 `swift test`。不需要本机构建 llama.cpp，也无需安装 Vulkan SDK。运行时从已加载的 llama.dll 所在目录寻找动态 CPU / Vulkan 后端。

`windows/scripts/package-brain.ps1` 收集实际 PE 导入闭包，并显式包含动态 CPU 变体、Vulkan 后端及 OpenMP 许可证。brain 目录可独立运行；没有 Vulkan 设备时使用 CPU。模型不打进 brain 目录，通过 configure 的 `generator: {kind:"builtin", modelPath:"绝对路径"}` 指定。

CI 缓存并校验固定 revision 的 Qwen3.5-0.8B Q4_K_M，执行 `python windows/scripts/check-builtin-model.py artifacts/brain/narrator-brain.exe $env:NARRATOR_TEST_MODEL`。该检查仅用打包目录的 DLL，通过 RPC 配置、snapshot、传感器回复和真实 overlay.show 验证标记，`artifacts/builtin-model-test/` 保存协议、stderr 和首条 / 整批毫秒指标。
