using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Interop.UIAutomationClient;

namespace LifeNarrator.Windows;

internal sealed class ContextSensor : IDisposable
{
    readonly BlockingCollection<Action> work = new();
    readonly Thread thread;
    readonly DisplayMap[] displays;
    readonly Action<string, object> emit;
    readonly Action<string> failed;
    readonly Func<DateTimeOffset> lastTypedAt, scrollAt;
    IUIAutomation automation = null!;
    readonly List<(TextLine Line, IUIAutomationTextRange? Range)> lines = [];
    Snapshot? snapshot;
    nint window;
    int requested = 1;
    DateTimeOffset lastRead, lastScroll;
    DisplayMap display = null!;

    public ContextSensor(DisplayMap[] displays, Action<string, object> emit, Action<string> failed,
        Func<DateTimeOffset> lastTypedAt, Func<DateTimeOffset> scrollAt)
    {
        this.displays = displays; this.emit = emit; this.failed = failed;
        this.lastTypedAt = lastTypedAt; this.scrollAt = scrollAt;
        thread = new Thread(Run) { IsBackground = true, Name = "LifeNarrator UIA" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    public void RequestRead() => Interlocked.Exchange(ref requested, 1);

    public Task<object?> Call(string method, JsonElement parameters)
    {
        var source = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        work.Add(() =>
        {
            try { source.SetResult(Handle(method, parameters)); }
            catch (Exception error) { source.SetException(error); }
        });
        return source.Task;
    }

    void Run()
    {
        automation = new CUIAutomation();
        while (!work.IsCompleted)
        {
            if (work.TryTake(out var action, 50)) action();
            if (work.IsAddingCompleted) continue;
            try { Tick(); }
            catch (Exception error) when (error is COMException or Win32Exception or InvalidOperationException or ArgumentException)
            {
                // UIA providers and windows can disappear between calls; expose the failure.
                failed("UIA: " + error.Message);
            }
        }
        lines.Clear();
        Marshal.ReleaseComObject(automation);
    }

    void Tick()
    {
        var now = DateTimeOffset.UtcNow;
        var foreground = Native.GetForegroundWindow();
        var switched = foreground != window;
        var readRequested = Interlocked.Exchange(ref requested, 0) != 0;
        if (switched)
        {
            window = foreground;
            lines.Clear();
            emit("windowChanged", new { });
        }
        if (window == 0) { snapshot = null; return; }
        Native.GetWindowThreadProcessId(window, out var pid);
        if (pid == Environment.ProcessId) { snapshot = null; return; }
        if (!Native.GetWindowRect(window, out var physicalFrame)) throw new Win32Exception();
        var index = Array.FindIndex(displays, d => d.Bounds.Contains(new Avalonia.PixelPoint(
            physicalFrame.Left + (physicalFrame.Right - physicalFrame.Left) / 2,
            physicalFrame.Top + (physicalFrame.Bottom - physicalFrame.Top) / 2)));
        if (index < 0) index = 0;
        var nextDisplay = displays[index];
        var frame = nextDisplay.Logical(physicalFrame.Box);
        var moved = snapshot != null && snapshot.WindowFrame != frame;
        var scaleChanged = snapshot != null && display != nextDisplay;
        display = nextDisplay;
        if (moved && !switched)
        {
            if (scaleChanged) emit("windowChanged", new { });
            else emit("windowFrameChanged", new { frame });
        }
        var scroll = scrollAt();
        var scrollDue = scroll > lastScroll && (now - scroll).TotalMilliseconds >= 300;
        if (!(switched || moved || readRequested || scrollDue ||
            (Native.IdleSeconds() < 3 && (now - lastRead).TotalSeconds >= 3))) return;
        lastRead = now;
        if (scrollDue) lastScroll = scroll;
        Capture(frame, index, switched || scaleChanged);
    }

    static Box Physical(tagRECT r) => new(r.left, r.top, r.right - r.left, r.bottom - r.top);

    void Capture(Box frame, int screenIndex, bool changed)
    {
        var root = automation.ElementFromHandle(window);
        using var process = Process.GetProcessById(root.CurrentProcessId);
        var app = process.ProcessName;
        var previous = snapshot;
        var collected = new List<(TextLine Line, IUIAutomationTextRange? Range)>();
        var seen = new HashSet<(string, Box)>();
        var sensitive = new List<Box>();
        string? url = null;
        var walker = automation.ControlViewWalker;
        var stack = new Stack<IUIAutomationElement>();
        stack.Push(root);
        var count = 0;
        while (stack.TryPop(out var element) && count++ < 4000)
        {
            if (element.CurrentIsOffscreen == 0)
            {
                var bounds = display.Logical(Physical(element.CurrentBoundingRectangle));
                if (element.CurrentIsPassword != 0) sensitive.Add(bounds);
                else
                {
                    var role = element.CurrentControlType switch { 50000 => "button", 50005 => "link", 50004 => "field", _ => "text" };
                    var hasText = (bool)element.GetCurrentPropertyValue(30040);
                    if ((app.Equals("msedge", StringComparison.OrdinalIgnoreCase) || app.Equals("chrome", StringComparison.OrdinalIgnoreCase))
                        && element.CurrentControlType == 50004 && (bool)element.GetCurrentPropertyValue(30043)
                        && (element.CurrentAutomationId is "addressEditBox" or "omnibox"
                            || element.CurrentName.Contains("address", StringComparison.OrdinalIgnoreCase)
                            || element.CurrentName.Contains("地址")))
                    {
                        var value = ((IUIAutomationValuePattern)element.GetCurrentPattern(10002)).CurrentValue;
                        if (Uri.TryCreate(value.Contains("://") ? value : "https://" + value, UriKind.Absolute, out var uri)
                            && uri.Scheme is "http" or "https" && uri.Host.Contains('.')) url = uri.AbsoluteUri;
                    }
                    if (hasText)
                    {
                        var pattern = (IUIAutomationTextPattern)element.GetCurrentPattern(10014);
                        var ranges = pattern.GetVisibleRanges();
                        for (var i = 0; i < ranges.Length; i++) AddRange(ranges.GetElement(i), role);
                    }
                    else Add(element.CurrentName, bounds, role, null);
                }
            }
            // Depth-first control-view traversal, bounded before requesting more elements.
            if (count + stack.Count < 4000)
            {
                var sibling = element == root ? null : walker.GetNextSiblingElement(element);
                if (sibling != null) stack.Push(sibling);
                var child = walker.GetFirstChildElement(element);
                if (child != null) stack.Push(child);
            }
        }
        if (Native.GetForegroundWindow() != window) { RequestRead(); return; }
        lines.Clear(); lines.AddRange(collected);
        var focused = automation.GetFocusedElement();
        var contentTop = Math.Min(frame.Y + 88, frame.Y + frame.H);
        snapshot = new Snapshot(app, app, root.CurrentProcessId, root.CurrentName, url,
            url == null ? null : new Uri(url).Host, frame,
            new Box(frame.X, contentTop, frame.W, frame.Y + frame.H - contentTop), screenIndex,
            lines.Select(x => x.Line).ToArray(), lines.Count == 0 ? "none" : "ax", sensitive.ToArray(),
            focused.CurrentIsPassword != 0, frame.Rect.Contains(display.Logical(display.Bounds).Rect), DateTimeOffset.UtcNow);
        var unchanged = previous != null && JsonSerializer.Serialize(previous with { CapturedAt = snapshot.CapturedAt }, Protocol.Json)
            == JsonSerializer.Serialize(snapshot, Protocol.Json);
        if (!changed && unchanged) return;
        emit("snapshot", new { snapshot, windowID = unchecked((uint)window), change = new
        {
            appChanged = previous?.Pid != snapshot.Pid, windowChanged = changed,
            hostChanged = previous?.Host != snapshot.Host
        } });

        void Add(string text, Box bounds, string role, IUIAutomationTextRange? range)
        {
            if (string.IsNullOrWhiteSpace(text) || bounds.W <= 0 || bounds.H <= 0 || !frame.Rect.Intersects(bounds.Rect)) return;
            if (seen.Add((text, bounds))) collected.Add((new TextLine(text, bounds, role), range));
            else if (range != null)
            {
                var existing = collected.FindIndex(x => x.Line.Text == text && x.Line.Rect == bounds);
                if (collected[existing].Range == null) collected[existing] = (collected[existing].Line, range);
            }
        }

        void AddRange(IUIAutomationTextRange visible, string role)
        {
            var cursor = visible.Clone();
            cursor.MoveEndpointByRange(TextPatternRangeEndpoint.TextPatternRangeEndpoint_End, cursor,
                TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start);
            while (cursor.CompareEndpoints(TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start, visible,
                TextPatternRangeEndpoint.TextPatternRangeEndpoint_End) < 0 && collected.Count < 4000)
            {
                var line = cursor.Clone();
                line.ExpandToEnclosingUnit(TextUnit.TextUnit_Line);
                if (line.CompareEndpoints(TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start, visible,
                    TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start) < 0)
                    line.MoveEndpointByRange(TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start, visible,
                        TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start);
                if (line.CompareEndpoints(TextPatternRangeEndpoint.TextPatternRangeEndpoint_End, visible,
                    TextPatternRangeEndpoint.TextPatternRangeEndpoint_End) > 0)
                    line.MoveEndpointByRange(TextPatternRangeEndpoint.TextPatternRangeEndpoint_End, visible,
                        TextPatternRangeEndpoint.TextPatternRangeEndpoint_End);
                var text = line.GetText(-1).TrimEnd('\r', '\n');
                var rectangles = (double[])line.GetBoundingRectangles();
                if (rectangles.Length >= 4) Add(text, Union(rectangles), role, line);
                if (cursor.CompareEndpoints(TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start, line,
                    TextPatternRangeEndpoint.TextPatternRangeEndpoint_End) >= 0) break;
                cursor.MoveEndpointByRange(TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start, line,
                    TextPatternRangeEndpoint.TextPatternRangeEndpoint_End);
            }
        }
    }

    Box Union(double[] rectangles)
    {
        var rect = new Avalonia.Rect(rectangles[0], rectangles[1], rectangles[2], rectangles[3]);
        for (var i = 4; i < rectangles.Length; i += 4)
            rect = rect.Union(new Avalonia.Rect(rectangles[i], rectangles[i + 1], rectangles[i + 2], rectangles[i + 3]));
        return display.Logical(Box.From(rect));
    }

    object? Handle(string method, JsonElement p)
    {
        switch (method)
        {
            case "sensor.isTyping":
                var focus = automation.GetFocusedElement();
                return (p.GetProperty("now").GetDateTimeOffset() - lastTypedAt()).TotalSeconds < 2
                    && focus.CurrentIsKeyboardFocusable != 0 && (focus.CurrentControlType == 50004 ||
                        ((bool)focus.GetCurrentPropertyValue(30043) &&
                         ((IUIAutomationValuePattern)focus.GetCurrentPattern(10002)).CurrentIsReadOnly == 0)
                        || ((bool)focus.GetCurrentPropertyValue(30040) &&
                            ((IUIAutomationTextPattern)focus.GetCurrentPattern(10014)).DocumentRange.GetAttributeValue(40015) is false));
            case "sensor.isSecureFocused": return automation.GetFocusedElement().CurrentIsPassword != 0;
            case "sensor.idleSeconds": return Native.IdleSeconds();
            case "sensor.lastTypedAt": return lastTypedAt();
            case "sensor.isLowPowerMode":
                if (!Native.GetSystemPowerStatus(out var power)) throw new Win32Exception();
                return power.SystemStatusFlag == 1;
            case "sensor.refresh": lastRead = default; RequestRead(); Tick(); return null;
            case "sensor.boundsProbe": return lines.Any(x => x.Range != null);
            case "sensor.startVisualLines": case "sensor.markTrack": return null;
            case "sensor.placementObstacles": return Array.Empty<Box>();
            case "sensor.placementLine": return lines[p.GetProperty("lineIndex").GetInt32()].Line.Rect;
            case "sensor.textRect": case "sensor.unframedRect":
                var entry = lines[p.GetProperty("lineIndex").GetInt32()];
                var range = p.GetProperty("range").Read<TextSpan>();
                var rect = Estimate(entry.Line, range);
                var kind = "estimated";
                if (method == "sensor.textRect" && entry.Range != null)
                {
                    // FindText preserves UTF-16 offsets without assuming UIA Character means one code unit.
                    var needle = entry.Line.Text.Substring(range.Location, range.Length);
                    var prefix = entry.Range.Clone();
                    if (range.Location > 0)
                    {
                        var before = prefix.FindText(entry.Line.Text[..range.Location], 0, 0);
                        if (before == null) return new { rect, kind };
                        prefix.MoveEndpointByRange(TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start,
                            before, TextPatternRangeEndpoint.TextPatternRangeEndpoint_End);
                    }
                    var subrange = prefix.FindText(needle, 0, 0);
                    if (subrange != null)
                    {
                        var rectangles = (double[])subrange.GetBoundingRectangles();
                        if (rectangles.Length >= 4) { rect = Union(rectangles); kind = "bounds"; }
                    }
                }
                return method == "sensor.textRect" ? new { rect, kind } : rect;
            default: throw new MissingMethodException(method);
        }
    }

    internal static Box Estimate(TextLine line, TextSpan range) => new(
        line.Rect.X + line.Rect.W * range.Location / line.Text.Length, line.Rect.Y,
        line.Rect.W * range.Length / line.Text.Length, line.Rect.H);

    public void Dispose() => work.CompleteAdding();
}
