using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Avalonia;
using Interop.UIAutomationClient;

namespace LifeNarrator.Windows;

internal static class UiaSpike
{
    const string English = "LifeNarrator visible English paragraph";
    const string Chinese = "生活旁白：又要上班了！";
    record Box(double X, double Y, double Width, double Height);
    record Segment(string Source, string Role, string Text, Box[] Rectangles);
    static Box Rect(tagRECT r) => new(r.left, r.top, r.right - r.left, r.bottom - r.top);

    public static void Run()
    {
        var fixture = Artifact.PathFor("fixtures");
        Directory.CreateDirectory(fixture);
        var textFile = Path.Combine(fixture, "T19-notepad.txt");
        File.WriteAllText(textFile, $"{English}\r\nSecond English line\r\n{Chinese}\r\n这是中文第二行。", new UTF8Encoding(true));
        var html = Path.Combine(fixture, "T19-edge.html");
        File.WriteAllText(html, $"<!doctype html><html lang='zh'><meta charset='utf-8'><title>T19 Edge fixture</title>"
            + $"<body style='margin:40px;font:24px/40px sans-serif'><p>{English}</p><p>{Chinese}</p>"
            + "<p>Third visible line</p><a href='#test'>Fixture link</a><button>Fixture button</button></body></html>");
        var automation = new CUIAutomation();
        var results = new List<object>();
        var owned = new List<Process>();
        try
        {
            owned.Add(Process.Start(new ProcessStartInfo("notepad.exe") { ArgumentList = { textFile } })!);
            ReadTarget("notepad", "T19-notepad.txt");
            var edge = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                "Microsoft", "Edge", "Application", "msedge.exe");
            owned.Add(Process.Start(new ProcessStartInfo(edge) { ArgumentList = {
                "--user-data-dir=" + Path.Combine(fixture, "edge-profile"), "--force-renderer-accessibility",
                "--no-first-run", "--no-default-browser-check", "--new-window", new Uri(html).AbsoluteUri } })!);
            ReadTarget("edge", "T19 Edge fixture");
            Artifact.Write("uia.json", new { coordinateSpace = "physical screen pixels (PerMonitorV2)",
                chromiumAccessibility = "--force-renderer-accessibility", targets = results });
        }
        finally
        {
            foreach (var process in owned)
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
                process.Dispose();
            }
        }

        void ReadTarget(string name, string title)
        {
            var condition = automation.CreateTrueCondition();
            IUIAutomationElement? target = null;
            var timer = Stopwatch.StartNew();
            while (timer.Elapsed < TimeSpan.FromSeconds(30))
            {
                var windows = automation.GetRootElement().FindAll(TreeScope.TreeScope_Children, condition);
                for (var i = 0; i < windows.Length; i++)
                {
                    var element = windows.GetElement(i);
                    if (element.CurrentName.Contains(title)) { target = element; break; }
                }
                if (target != null) break;
                Thread.Sleep(200);
            }
            if (target == null) throw new Exception($"No UIA window for {title}");
            var handle = target.CurrentNativeWindowHandle;
            if (!Native.SetForegroundWindow(handle)) throw new Exception($"Cannot foreground {title}");
            Thread.Sleep(1500);
            if (Native.GetForegroundWindow() != handle) throw new Exception($"Foreground is not {title}");
            var segments = new List<Segment>();
            var errors = new List<string>();
            var elements = target.FindAll(TreeScope.TreeScope_Subtree, condition);
            for (var i = 0; i < elements.Length; i++)
            {
                try
                {
                    var element = elements.GetElement(i);
                    if (element.CurrentIsOffscreen != 0) continue;
                    var role = $"{element.CurrentControlType}:{element.CurrentLocalizedControlType}";
                    var text = element.CurrentName;
                    if (!string.IsNullOrWhiteSpace(text)) segments.Add(new("element", role, text, [Rect(element.CurrentBoundingRectangle)]));
                    if (!(bool)element.GetCurrentPropertyValue(30040)) continue; // UIA_IsTextPatternAvailablePropertyId
                    var pattern = (IUIAutomationTextPattern)element.GetCurrentPattern(10014);
                    var ranges = pattern.GetVisibleRanges();
                    for (var r = 0; r < ranges.Length; r++)
                    {
                        var range = ranges.GetElement(r);
                        var rectangles = (double[])range.GetBoundingRectangles();
                        var boxes = Enumerable.Range(0, rectangles.Length / 4)
                            .Select(k => new Box(rectangles[k * 4], rectangles[k * 4 + 1], rectangles[k * 4 + 2], rectangles[k * 4 + 3])).ToArray();
                        segments.Add(new("TextPattern.visibleRange", role, range.GetText(-1), boxes));
                    }
                }
                catch (COMException error) { errors.Add($"element {i}: 0x{error.HResult:X8}: {error.Message}"); }
            }
            var bounds = Rect(target.CurrentBoundingRectangle);
            var body = segments.Where(x => x.Text.Contains(English) || x.Text.Contains(Chinese)).ToArray();
            var bodyRectangles = body.SelectMany(x => x.Rectangles).ToArray();
            var rectanglesInWindow = bodyRectangles.Length > 0 && bodyRectangles.All(r => r.Width > 0 && r.Height > 0
                && r.X >= bounds.X && r.Y >= bounds.Y && r.X + r.Width <= bounds.X + bounds.Width + 1
                && r.Y + r.Height <= bounds.Y + bounds.Height + 1);
            Native.CaptureScreen(Artifact.PathFor($"uia-{name}.png"), new PixelRect(0, 0, Native.GetSystemMetrics(0), Native.GetSystemMetrics(1)));
            results.Add(new { name, title = target.CurrentName, window = bounds, foreground = true, segments, errors,
                englishReadable = body.Any(x => x.Text.Contains(English)), chineseReadable = body.Any(x => x.Text.Contains(Chinese)),
                bodyRectanglesInWindow = rectanglesInWindow, bodySegments = body.Length });
        }
    }
}
