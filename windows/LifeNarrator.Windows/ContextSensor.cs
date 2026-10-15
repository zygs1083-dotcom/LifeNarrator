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
    sealed class Entry(TextLine line, IUIAutomationElement? element, IUIAutomationTextRange? range,
        Box origin, WindowOcr.Line? ocr = null)
    {
        public TextLine Line = line;
        public IUIAutomationElement? Element = element;
        public IUIAutomationTextRange? Range = range;
        public Box Origin = origin;
        public Box BoundsOrigin = origin;
        public WindowOcr.Line? Ocr = ocr;
    }
    sealed record Track(Entry Entry, Box Origin, DisplayMap Display);
    internal record TrackSample(string Id, Box? Offset);
    readonly List<Entry> lines = [];
    readonly Dictionary<string, Track> tracks = [];
    readonly Action<bool> ocrUnavailable;
    readonly Action scrolled;
    WindowOcr ocr = null!;
    IUIAutomationElement? scrollRoot;
    ScrollEvents? scrollEvents;
    Snapshot? snapshot;
    nint window;
    int requested = 1;
    DateTimeOffset lastRead, lastScroll;
    DisplayMap display = null!;
    bool hasTextPattern, visualLinesRequested;

    public ContextSensor(DisplayMap[] displays, Action<string, object> emit, Action<string> failed,
        Func<DateTimeOffset> lastTypedAt, Func<DateTimeOffset> scrollAt, Action scrolled, Action<bool> ocrUnavailable)
    {
        this.displays = displays; this.emit = emit; this.failed = failed;
        this.lastTypedAt = lastTypedAt; this.scrollAt = scrollAt;
        this.scrolled = scrolled; this.ocrUnavailable = ocrUnavailable;
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
        automation = new CUIAutomation8();
        var timeouts = (IUIAutomation2)automation;
        timeouts.ConnectionTimeout = 100;
        timeouts.TransactionTimeout = 100;
        ocr = new WindowOcr(ocrUnavailable);
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
        if (scrollRoot != null) automation.RemovePropertyChangedEventHandler(scrollRoot, scrollEvents!);
        lines.Clear(); tracks.Clear();
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
            lines.Clear(); tracks.Clear();
            if (scrollRoot != null) automation.RemovePropertyChangedEventHandler(scrollRoot, scrollEvents!);
            scrollRoot = null;
            hasTextPattern = false; visualLinesRequested = false;
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
        if (scrollRoot == null)
        {
            scrollRoot = root;
            scrollEvents = new ScrollEvents(scrolled);
            automation.AddPropertyChangedEventHandler(root, TreeScope.TreeScope_Subtree, null, scrollEvents,
                [30053, 30054]); // ScrollPattern horizontal/vertical scroll percent
        }
        var collected = new List<Entry>();
        var seen = new HashSet<(string, Box)>();
        var sensitive = new List<Box>();
        string? url = null;
        var foundTextPattern = false;
        var walker = automation.ControlViewWalker;
        var stack = new Stack<IUIAutomationElement>();
        stack.Push(root);
        var count = 0;
        var contentTop = Math.Min(frame.Y + 88, frame.Y + frame.H);
        var content = new Box(frame.X, contentTop, frame.W, frame.Y + frame.H - contentTop);
        var foundDocument = false;
        while (stack.TryPop(out var element) && count++ < 4000)
        {
            if (element.CurrentIsOffscreen == 0)
            {
                var bounds = display.Logical(Physical(element.CurrentBoundingRectangle));
                if (!foundDocument && element.CurrentControlType == 50030 && bounds.W > 0 && bounds.H > 0)
                {
                    content = Box.From(frame.Rect.Intersect(bounds.Rect));
                    foundDocument = true;
                }
                if (element.CurrentIsPassword != 0) sensitive.Add(bounds);
                else
                {
                    var role = element.CurrentControlType switch { 50000 => "button", 50005 => "link", 50004 => "field", _ => "text" };
                    var hasText = (bool)element.GetCurrentPropertyValue(30040);
                    foundTextPattern |= hasText;
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
                        for (var i = 0; i < ranges.Length; i++) AddRange(ranges.GetElement(i), role, element);
                    }
                    else Add(element.CurrentName, bounds, role, element, null, bounds);
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
        hasTextPattern = foundTextPattern;
        var focused = automation.GetFocusedElement();
        var secure = focused.CurrentIsPassword != 0;
        var needsOcr = visualLinesRequested || lines.Count(x => x.Line.Role == "text" && content.Rect.Contains(x.Line.Rect.Rect)) < 3;
        visualLinesRequested = false;
        if (needsOcr && !secure)
        {
            var recognized = ocr.Read(window, display.Physical(frame), display);
            if (recognized.Length > 0)
            {
                lines.Clear();
                lines.AddRange(recognized.Where(x => content.Rect.Contains(x.TextLine.Rect.Rect)
                    && !sensitive.Any(r => r.Rect.Intersects(x.TextLine.Rect.Rect)))
                    .Select(x => new Entry(x.TextLine, null, null, x.TextLine.Rect, x)));
            }
        }
        if (Native.GetForegroundWindow() != window) { RequestRead(); return; }
        snapshot = new Snapshot(app, app, root.CurrentProcessId, root.CurrentName, url,
            url == null ? null : new Uri(url).Host, frame,
            content, screenIndex,
            lines.Select(x => x.Line).ToArray(), lines.Count == 0 ? "none" : lines[0].Ocr != null ? "ocr" : "ax", sensitive.ToArray(),
            secure, frame.Rect.Contains(display.Logical(display.Bounds).Rect), DateTimeOffset.UtcNow);
        var unchanged = previous != null && JsonSerializer.Serialize(previous with { CapturedAt = snapshot.CapturedAt }, Protocol.Json)
            == JsonSerializer.Serialize(snapshot, Protocol.Json);
        if (!changed && unchanged) return;
        if (Environment.GetEnvironmentVariable("LIFENARRATOR_DEBUG") == "1")
            Console.Error.WriteLine($"[sensor] snapshot source={snapshot.TextSource} lines={lines.Count}");
        emit("snapshot", new { snapshot, windowID = unchecked((uint)window), change = new
        {
            appChanged = previous?.Pid != snapshot.Pid, windowChanged = changed,
            hostChanged = previous?.Host != snapshot.Host
        } });

        void Add(string text, Box bounds, string role, IUIAutomationElement element, IUIAutomationTextRange? range, Box origin)
        {
            if (string.IsNullOrWhiteSpace(text) || bounds.W <= 0 || bounds.H <= 0 || !frame.Rect.Intersects(bounds.Rect)) return;
            if (seen.Add((text, bounds))) collected.Add(new Entry(new TextLine(text, bounds, role), element, range, origin));
            else if (range != null)
            {
                var existing = collected.FindIndex(x => x.Line.Text == text && x.Line.Rect == bounds);
                if (collected[existing].Range == null) collected[existing] = new Entry(collected[existing].Line, element, range, origin);
            }
        }

        void AddRange(IUIAutomationTextRange visible, string role, IUIAutomationElement element)
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
                if (rectangles.Length >= 4) Add(text, Union(rectangles), role, element, line, Union(rectangles));
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
            case "sensor.boundsProbe": return hasTextPattern;
            case "sensor.startVisualLines": visualLinesRequested = true; RequestRead(); return null;
            case "sensor.markTrack":
                var tracked = lines[p.GetProperty("lineIndex").GetInt32()];
                if (tracked.Element == null) return null;
                var id = Guid.NewGuid().ToString("N");
                var origin = p.TryGetProperty("kind", out var k) && k.GetString() == "bounds" ? tracked.BoundsOrigin : tracked.Origin;
                tracks.Add(id, new Track(tracked, origin, display));
                return id;
            case "sensor.placementObstacles": return Array.Empty<Box>();
            case "sensor.placementLine": return lines[p.GetProperty("lineIndex").GetInt32()].Line.Rect;
            case "sensor.textRect": case "sensor.unframedRect":
                var entry = lines[p.GetProperty("lineIndex").GetInt32()];
                var range = p.GetProperty("range").Read<TextSpan>();
                var rect = Estimate(entry.Line, range);
                var kind = "estimated";
                if (entry.Ocr != null)
                {
                    rect = WindowOcr.TextRect(entry.Ocr, range);
                    if (Environment.GetEnvironmentVariable("LIFENARRATOR_DEBUG") == "1")
                        Console.Error.WriteLine("[sensor] textRect kind=ocr rect=" + JsonSerializer.Serialize(rect, Protocol.Json));
                    return method == "sensor.textRect" ? new { rect, kind = "ocr" } : rect;
                }
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
                        if (rectangles.Length >= 4)
                        {
                            rect = Union(rectangles); kind = "bounds";
                            entry.BoundsOrigin = Union((double[])entry.Range.GetBoundingRectangles());
                        }
                    }
                }
                return method == "sensor.textRect" ? new { rect, kind } : rect;
            default: throw new MissingMethodException(method);
        }
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    sealed class ScrollEvents(Action changed) : IUIAutomationPropertyChangedEventHandler
    {
        public void HandlePropertyChangedEvent(IUIAutomationElement sender, int propertyId, object newValue) => changed();
    }

    public Task<TrackSample[]> ReadTracks(string[] ids)
    {
        var source = new TaskCompletionSource<TrackSample[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        work.Add(() =>
        {
            try
            {
                var samples = new List<TrackSample>();
                foreach (var id in ids)
                {
                    if (!tracks.TryGetValue(id, out var track)) { samples.Add(new(id, null)); continue; }
                    try
                    {
                        var entry = track.Entry;
                        if (entry.Element!.CurrentIsOffscreen != 0) { samples.Add(new(id, null)); continue; }
                        Box bounds;
                        if (entry.Range != null)
                        {
                            var rectangles = (double[])entry.Range.GetBoundingRectangles();
                            if (rectangles.Length < 4 || entry.Range.GetText(-1).TrimEnd('\r', '\n') != entry.Line.Text)
                            { samples.Add(new(id, null)); continue; }
                            var r = rectangles;
                            var union = new Avalonia.Rect(r[0], r[1], r[2], r[3]);
                            for (var i = 4; i < r.Length; i += 4) union = union.Union(new Avalonia.Rect(r[i], r[i + 1], r[i + 2], r[i + 3]));
                            bounds = track.Display.Logical(Box.From(union));
                        }
                        else bounds = track.Display.Logical(Physical(entry.Element.CurrentBoundingRectangle));
                        samples.Add(new(id, new Box(bounds.X - track.Origin.X, bounds.Y - track.Origin.Y, bounds.W, bounds.H)));
                    }
                    catch (COMException error) when (error.HResult == unchecked((int)0x80040201))
                    { samples.Add(new(id, null)); } // UIA_E_ELEMENTNOTAVAILABLE
                    catch (COMException error) when (error.HResult == unchecked((int)0x80131505))
                    { } // UIA_E_TIMEOUT: leave this mark unchanged for this frame.
                }
                source.SetResult(samples.ToArray());
            }
            catch (Exception error) { source.SetException(error); }
        });
        return source.Task;
    }

    public void ReleaseTrack(string id) => work.Add(() => tracks.Remove(id));

    internal static Box Estimate(TextLine line, TextSpan range) => new(
        line.Rect.X + line.Rect.W * range.Location / line.Text.Length, line.Rect.Y,
        line.Rect.W * range.Length / line.Text.Length, line.Rect.H);

    public void Dispose() => work.CompleteAdding();
}
