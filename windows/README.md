# T19 Windows spike

This is a technical verification harness, not an application. The shared Swift core stays in-process on macOS; this executable only establishes the future Windows stdio boundary.

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

No engine state, scheduling, streaming generation, model loading or settings are exposed in this spike. Those belong to T20/W1.

## Evidence interpretation

- `overlay.json` reports the actual Win32 extended styles, actual Avalonia transparency level and foreground handle before/after showing the overlay. The runner uses software rendering and a redirection surface without relying on a GPU. Win32Properties.AddWindowStylesCallback preserves the custom flags when Avalonia recomputes window styles; SetLayeredWindowAttributes enables the layered window after showing it.
- `uia.json` preserves every visible named element and TextPattern visible range with physical screen rectangles and control type/role. ValuePattern is recorded separately as a full-value/edit-control rectangle, never as a visible line range; classic Notepad on the runner lacks TextPattern. Each fixture reports whether both known Chinese and English body strings were found, and whether their rectangles lie inside its window. Screenshots `uia-notepad.png` and `uia-edge.png` allow visual comparison. This bounds check alone does not establish glyph-level accuracy or mixed-DPI behavior. Edge is launched with `--force-renderer-accessibility` and a disposable profile; the result must not be generalized to every existing Chromium session.
- `brain.json` preserves requests, responses, elapsed milliseconds, exit code and stderr. The runner removes installed Swift directories from PATH for this mode, so the process must use the packaged runtime.
- `ocr.json` reports installed OCR languages, the selected language, text, word rectangles and source image dimensions. Chinese OCR requires an installed Chinese language pack. English-only recognition cannot establish Chinese OCR quality.

API references: [Avalonia headless rendering](https://docs.avaloniaui.net/docs/testing/setting-up-the-headless-platform), [UIA text ranges](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-usingtextrangeobjects), [extended window styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles), [Windows.Media.Ocr](https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrengine).
