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
            Artifact.Write("e2e-probe.json", new { window = root.CurrentName, text = range.GetText(-1), rectangles, rect = Box.From(rect) });
            return;
        }
        throw new InvalidOperationException("The follow fixture text has no visible UIA range");
    }
}
