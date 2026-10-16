using Interop.UIAutomationClient;

namespace LifeNarrator.Windows;

// Independent UIA evidence used by the Windows end-to-end harness.
internal static class FollowProbe
{
    public static void Run()
    {
        var automation = new CUIAutomation8();
        var root = automation.ElementFromHandle(Native.GetForegroundWindow());
        var elements = root.FindAll(TreeScope.TreeScope_Subtree, automation.CreatePropertyCondition(30040, true));
        for (var i = 0; i < elements.Length; i++)
        {
            var pattern = (IUIAutomationTextPattern)elements.GetElement(i).GetCurrentPattern(10014);
            const string quote = "visible English paragraph";
            var range = pattern.DocumentRange;
            var offset = range.GetText(-1).IndexOf(quote, StringComparison.Ordinal);
            if (offset < 0) continue;
            // This fixture is ASCII: UIA Character offsets are unambiguous here.
            range.MoveEndpointByRange(TextPatternRangeEndpoint.TextPatternRangeEndpoint_End, range,
                TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start);
            range.MoveEndpointByUnit(TextPatternRangeEndpoint.TextPatternRangeEndpoint_End, TextUnit.TextUnit_Character, offset + quote.Length);
            range.MoveEndpointByUnit(TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start, TextUnit.TextUnit_Character, offset);
            if (range.GetText(-1) != quote) throw new InvalidOperationException("Probe did not isolate the fixture quote");
            var rectangles = (double[])range.GetBoundingRectangles();
            if (rectangles.Length < 4) continue;
            var rect = new Avalonia.Rect(rectangles[0], rectangles[1], rectangles[2], rectangles[3]);
            for (var j = 4; j < rectangles.Length; j += 4)
                rect = rect.Union(new Avalonia.Rect(rectangles[j], rectangles[j + 1], rectangles[j + 2], rectangles[j + 3]));
            var window = Native.GetForegroundWindow();
            if (!Native.GetWindowRect(window, out var bounds)) throw new System.ComponentModel.Win32Exception();
            var display = new DisplayMap(new Avalonia.PixelRect(bounds.Left, bounds.Top,
                bounds.Right - bounds.Left, bounds.Bottom - bounds.Top), default, 1);
            var mask = Box.From(rect);
            var jpeg = WindowImage.Capture(window, bounds.Box, [mask], display);
            using (var decoded = SkiaSharp.SKBitmap.Decode(jpeg))
            {
                if (Math.Max(decoded.Width, decoded.Height) > 1280) throw new Exception("Vision image exceeds 1280px");
                var pixel = decoded.GetPixel((int)((mask.X + mask.W / 2 - bounds.Left) * decoded.Width / bounds.Box.W),
                    (int)((mask.Y + mask.H / 2 - bounds.Top) * decoded.Height / bounds.Box.H));
                if (pixel.Red > 10 || pixel.Green > 10 || pixel.Blue > 10) throw new Exception("Vision redaction is not black");
            }
            File.WriteAllBytes(Artifact.PathFor("e2e-vision.jpg"), jpeg);
            try
            {
                WindowImage.Capture(window, bounds.Box.Offset(1, 0), [], display);
                throw new Exception("Vision accepted a stale window frame");
            }
            catch (WindowUnavailableException) { }
            Artifact.Write("e2e-probe.json", new { window = root.CurrentName, text = range.GetText(-1), rectangles, rect = Box.From(rect) });
            return;
        }
        throw new InvalidOperationException("The follow fixture text has no visible UIA range");
    }
}
