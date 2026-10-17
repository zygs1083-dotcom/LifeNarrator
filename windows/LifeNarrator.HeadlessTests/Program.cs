using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using LifeNarrator.Windows;

if (args.SequenceEqual(new[] { "--updates-only" })) { UpdateChecks.Run().GetAwaiter().GetResult(); return; }
if (args.SequenceEqual(new[] { "--builtin-batch-only" })) { BuiltinModelBatchChecks.Run().GetAwaiter().GetResult(); return; }
BuiltinModelBatchChecks.Run().GetAwaiter().GetResult();
if (args.SequenceEqual(new[] { "--download-responsiveness-only" }))
{
    AppBuilder.Configure<Application>().UseSkia()
        .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false }).SetupWithoutStarting();
    DownloadResponsivenessChecks.Run(); return;
}
var restOnly = args.SequenceEqual(new[] { "--rest-only" });
var bubblesOnly = args.SequenceEqual(new[] { "--bubbles-only" });
SettingsChecks.Run();
if (args.Length == 0) UpdateChecks.Run().GetAwaiter().GetResult();
if (args.Length > 0 && !bubblesOnly && !restOnly) BrainChecks.Run(args[0]).GetAwaiter().GetResult();
var map = new DisplayMap(new PixelRect(-1920, 120, 1920, 1080), new PixelRect(-1920, 120, 1920, 1040), 1.5);
var physical = new Box(-1770, 270, 300, 60);
var logical = map.Logical(physical);
if (logical != new Box(-1820, 220, 200, 40) || map.Physical(logical) != physical) throw new Exception("DPI conversion failed");
var rectJson = JsonSerializer.SerializeToElement(logical, Protocol.Json);
if (rectJson.EnumerateObject().Count() != 4) throw new Exception("Rect has extra wire fields");
if (JsonSerializer.Serialize(DateTimeOffset.UtcNow, Protocol.Json).Contains('.')) throw new Exception("Fractional wire date");

AppBuilder.Configure<Application>().UseSkia()
    .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false }).SetupWithoutStarting();
if (bubblesOnly) { BubbleChecks.Run(); return; }
if (restOnly) { Application.Current!.Styles.Add(new AppTheme()); IconChecks.Run(); RestChecks.Run(); return; }
var window = new Window { Width = 600, Height = 320, Background = Brushes.Transparent, Content = new BubbleSample() };
window.Show();
using var bitmap = window.CaptureRenderedFrame() ?? throw new Exception("No rendered frame");
Directory.CreateDirectory("artifacts");
bitmap.Save("artifacts/bubble-headless.png");
using var pixels = bitmap.Lock();
var pixel = new byte[4];
Marshal.Copy(pixels.Address + 60 * pixels.RowBytes + 75 * 4, pixel, 0, 4);
if (pixel[3] != 255 || Math.Abs(pixel[0] - pixel[2]) > 30 || pixel[1] >= 220)
    throw new Exception($"Bubble fill missing: {string.Join(',', pixel)}");
window.Close();
Console.WriteLine("PASS: bubble rendered at 600x320; pink fill verified; artifacts/bubble-headless.png");

foreach (var rounded in new[] { false, true })
{
    var bubble = new BubbleVisual("windows-shell", "辛苦啦，慢慢来", ["😺"], "zh", new BubbleStyle { Shape = rounded ? "rounded" : "text", Size = "medium" });
    var sample = new Window { Width = bubble.Width, Height = bubble.Height, Background = Brushes.Transparent, Content = bubble };
    sample.Show();
    using var frame = sample.CaptureRenderedFrame() ?? throw new Exception("No bubble pixels");
    frame.Save($"artifacts/bubble-{(rounded ? "rounded" : "text")}.png");
    using var buffer = frame.Lock();
    var row = new byte[buffer.Size.Width * 4];
    var painted = 0;
    for (var y = 0; y < buffer.Size.Height; y++)
    {
        Marshal.Copy(buffer.Address + y * buffer.RowBytes, row, 0, row.Length);
        for (var x = 0; x < buffer.Size.Width; x++) if (row[x * 4 + 3] > 0) painted++;
    }
    if (painted < 300) throw new Exception("Bubble text/emoji did not render");
    sample.Close();
}
Console.WriteLine("PASS: text and rounded production bubbles rendered; negative-origin 150% DPI conversion; wire rectangles/dates");

BubbleChecks.Run();

UIChecks.Run();
SettingsSnapshots.Run();
SettingsInteractionChecks.Run();
ModelApiChecks.Run();

CompanionChecks.Run();
IconChecks.Run();
RestChecks.Run();
DownloadResponsivenessChecks.Run();
ModelDownloadChecks.Run(args.Length > 0 ? args[0] : null);
