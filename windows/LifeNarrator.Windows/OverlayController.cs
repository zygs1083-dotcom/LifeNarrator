using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;

namespace LifeNarrator.Windows;

internal sealed class OverlayController : IDisposable
{
    sealed record Surface(Window Window, Canvas Canvas, DisplayMap Map);
    sealed class Bubble(Narration narration, Surface surface, Control visual, Control? highlight, Box frame, Box? anchor)
    {
        public readonly Narration Narration = narration;
        public readonly Surface Surface = surface;
        public readonly Control Visual = visual;
        public readonly Control? Highlight = highlight;
        public Box Frame = frame;
        public Box? Anchor = anchor;
        public Box? Line = narration.Line;
        public Box[] Obstacles = narration.Obstacles;
        public double TrackX, TrackY;
        public WindowGeometry Window = narration.Window;
        public DateTimeOffset Born = DateTimeOffset.UtcNow;
        public DateTimeOffset? Dismissed;
        public bool Leaving;
    }
    readonly Surface[] surfaces;
    readonly List<Bubble> bubbles = [];
    readonly Settings settings;
    readonly DispatcherTimer timer;
    readonly DispatcherTimer followTimer = null!;
    readonly Action<string> failed;
    public ContextSensor Sensor { private get; set; } = null!;
    DateTimeOffset followUntil;
    bool following;
    int revision;
    public DisplayMap[] Displays => surfaces.Select(x => x.Map).ToArray();

    public OverlayController(Settings settings, Action<string> failed)
    {
        this.settings = settings; this.failed = failed;
        var probe = new Window();
        surfaces = probe.Screens.All.Select(screen =>
        {
            var canvas = new Canvas { IsHitTestVisible = false, ClipToBounds = true };
            var window = new Window
            {
                SystemDecorations = SystemDecorations.None, ShowInTaskbar = false, ShowActivated = false,
                Topmost = true, CanResize = false, Background = Brushes.Transparent, Content = canvas,
                TransparencyLevelHint = [WindowTransparencyLevel.Transparent],
                Position = screen.Bounds.Position, Width = screen.Bounds.Width / screen.Scaling,
                Height = screen.Bounds.Height / screen.Scaling
            };
            Win32Properties.AddWindowStylesCallback(window, (style, extended) => (style, extended | Native.OverlayExtendedStyles));
            window.Show();
            var handle = window.TryGetPlatformHandle()!.Handle;
            Native.ApplyOverlayStyles(handle);
            Native.EnableLayeredWindow(handle);
            return new Surface(window, canvas, new DisplayMap(screen.Bounds, screen.WorkingArea, screen.Scaling));
        }).ToArray();
        probe.Close();
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => Animate());
        timer.Start();
        followTimer = new DispatcherTimer(TimeSpan.FromSeconds(1d / 60), DispatcherPriority.Render, async (_, _) =>
        {
            if (DateTimeOffset.UtcNow > followUntil || !bubbles.Any(x => x.Dismissed == null && x.Narration.TrackID != null))
            { followTimer.Stop(); return; }
            try { await Follow(); }
            catch (Exception error) { followTimer.Stop(); failed("Follow: " + error.Message); }
        });
    }

    public async Task<object?> Call(string method, JsonElement parameters, BrainClient brain)
    {
        switch (method)
        {
            case "overlay.show": return await Show(parameters.GetProperty("narration").Read<Narration>(), brain);
            case "overlay.dismissAll": DismissAll(); return null;
            case "overlay.follow": await Follow(); return null;
            case "overlay.highlight": return bubbles.Find(x => x.Narration.Id == parameters.GetProperty("id").GetString() && x.Dismissed == null)?.Anchor;
            case "overlay.windowFrameChanged":
                Move(parameters.GetProperty("windowID").GetUInt32(), parameters.GetProperty("window").Read<WindowGeometry>()); return null;
            default: throw new MissingMethodException(method);
        }
    }

    async Task<object> Show(Narration narration, BrainClient brain)
    {
        var retained = false;
        try
        {
            var currentRevision = revision;
            var tierResult = await brain.Call("layout.sizeTier", new { requested = "medium", window = narration.Window });
            if (tierResult.ValueKind == JsonValueKind.Null) return new { shown = false, placement = "none" };
            var tier = tierResult.GetString()!;
            var surface = surfaces.FirstOrDefault(x => x.Map.Logical(x.Map.Bounds).Rect.Contains(narration.Window.Frame.Rect.Center)) ?? surfaces[0];
            var rounded = !narration.Framed;
            var fillOpacity = 1d;
            var visual = MakeVisual(rounded, false);
            var narrow = MakeVisual(rounded, true);
            Placement? placement = await Place(visual, narrow);
            if (placement?.Covered == true && !rounded)
            {
                rounded = true;
                fillOpacity = .92;
                visual = MakeVisual(true, false); narrow = MakeVisual(true, true);
                placement = await Place(visual, narrow);
            }
            if (placement == null || currentRevision != revision || settings.Paused) return new { shown = false, placement = "none" };
            var stack = bubbles.Where(x => x.Dismissed == null && x.Narration.WindowID == narration.WindowID && x.Narration.Anchor == null).Reverse().ToArray();
            if (placement.StackFrames != null)
                for (var i = 0; i < stack.Length; i++)
                {
                    var frame = placement.StackFrames[i + 1];
                    if (frame == null) Remove(stack[i]);
                    else { stack[i].Frame = frame; Position(stack[i]); }
                }
            while (bubbles.Count(x => x.Dismissed == null) >= settings.MaxOnScreen)
                Remove(bubbles.First(x => x.Dismissed == null));
            visual = placement.Narrow ? narrow : visual;
            var highlight = narration.Framed && placement.Highlight != null ? new Border
            {
                Width = placement.Highlight.W, Height = placement.Highlight.H,
                CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1),
                BorderBrush = Brush.Parse("#F55DC2"), Background = new SolidColorBrush(Color.Parse("#F55DC2"), .08)
            } : null;
            var bubble = new Bubble(narration, surface, visual, highlight, placement.Frame,
                placement.Highlight);
            visual.Opacity = 0;
            if (highlight != null) { highlight.Opacity = 0; surface.Canvas.Children.Add(highlight); }
            surface.Canvas.Children.Add(visual);
            bubbles.Add(bubble);
            retained = true;
            Position(bubble);
            await Follow(); // Catch scrolling during model generation before the first visible frame.
            Log("show", bubble);
            return new { shown = bubbles.Contains(bubble) && bubble.Dismissed == null, placement = placement.PlacementName };

            BubbleVisual MakeVisual(bool round, bool small) => new(narration.Id, narration.Text, narration.Emoji, narration.Language, tier, round, small, fillOpacity);
            async Task<Placement?> Place(BubbleVisual normal, BubbleVisual small)
            {
                var existing = bubbles.Where(x => x.Dismissed == null && x.Narration.WindowID == narration.WindowID).ToArray();
                var result = await brain.Call("layout.place", new
                {
                    size = new Dimensions(normal.Width, normal.Height), narrowSize = new Dimensions(small.Width, small.Height),
                    narration.Anchor, narration.Line, narration.Window,
                    visibleFrame = surface.Map.Logical(surface.Map.WorkArea),
                    occupied = existing.SelectMany(x => x.Anchor == null ? new[] { x.Frame } : new[] { x.Frame, x.Anchor }).ToArray(),
                    obstacles = narration.Obstacles, inkInset = new Dimensions(rounded ? 0 : 8, rounded ? 0 : 6),
                    stackSizes = existing.Where(x => x.Narration.Anchor == null).Reverse().Select(x => new Dimensions(x.Frame.W, x.Frame.H)).ToArray()
                });
                return result.ValueKind == JsonValueKind.Null ? null : Placement.Read(result);
            }
        }
        finally
        {
            if (!retained && narration.TrackID is { } id) Sensor.ReleaseTrack(id);
        }
    }

    void Position(Bubble bubble)
    {
        var map = bubble.Surface.Map;
        Canvas.SetLeft(bubble.Visual, bubble.Frame.X - map.Bounds.X);
        Canvas.SetTop(bubble.Visual, bubble.Frame.Y - map.Bounds.Y);
        if (bubble.Highlight != null && bubble.Anchor is { } anchor)
        {
            Canvas.SetLeft(bubble.Highlight, anchor.X - map.Bounds.X);
            Canvas.SetTop(bubble.Highlight, anchor.Y - map.Bounds.Y);
        }
    }

    void Move(uint windowID, WindowGeometry window)
    {
        revision++;
        foreach (var bubble in bubbles.Where(x => x.Narration.WindowID == windowID))
        {
            var dx = window.Frame.X - bubble.Window.Frame.X;
            var dy = window.Frame.Y - bubble.Window.Frame.Y;
            Translate(bubble, dx, dy);
            bubble.TrackX += dx; bubble.TrackY += dy;
            bubble.Window = window;
            Position(bubble);
        }
    }

    public void Scrolled(bool wheel)
    {
        if (wheel)
            foreach (var bubble in bubbles.Where(x => x.Dismissed == null && x.Anchor != null && x.Narration.TrackID == null).ToArray())
                Leave(bubble);
        followUntil = DateTimeOffset.UtcNow.AddSeconds(1);
        if (bubbles.Any(x => x.Dismissed == null && x.Narration.TrackID != null)) followTimer.Start();
    }

    async Task Follow()
    {
        if (following) return;
        var active = bubbles.Where(x => x.Dismissed == null && x.Narration.TrackID != null).ToArray();
        if (active.Length == 0) return;
        following = true;
        var currentRevision = revision;
        try
        {
            var samples = await Sensor.ReadTracks(active.Select(x => x.Narration.TrackID!).ToArray());
            if (currentRevision != revision) return;
            foreach (var sample in samples)
            {
                var bubble = active.First(x => x.Narration.TrackID == sample.Id);
                if (!bubbles.Contains(bubble) || bubble.Dismissed != null) continue;
                if (sample.Offset == null) { Leave(bubble); continue; }
                var dx = sample.Offset.X - bubble.TrackX;
                var dy = sample.Offset.Y - bubble.TrackY;
                Translate(bubble, dx, dy);
                bubble.TrackX = sample.Offset.X; bubble.TrackY = sample.Offset.Y;
                var window = bubble.Window;
                var content = new Rect(window.Frame.X, window.Frame.Y + window.ChromeHeight,
                    window.Frame.W, window.Frame.H - window.ChromeHeight);
                if (bubble.Anchor is { } anchor && !content.Contains(anchor.Rect)
                    || !bubble.Surface.Map.Logical(bubble.Surface.Map.WorkArea).Rect.Contains(bubble.Frame.Rect))
                { Leave(bubble); continue; }
                Position(bubble);
                if (Math.Abs(dx) >= .5 || Math.Abs(dy) >= .5) Log("follow", bubble);
            }
        }
        finally { following = false; }
    }

    static void Translate(Bubble bubble, double dx, double dy)
    {
        bubble.Frame = bubble.Frame.Offset(dx, dy);
        bubble.Anchor = bubble.Anchor?.Offset(dx, dy);
        bubble.Line = bubble.Line?.Offset(dx, dy);
        bubble.Obstacles = bubble.Obstacles.Select(r => r.Offset(dx, dy)).ToArray();
    }

    static void Log(string action, Bubble bubble)
    {
        if (Environment.GetEnvironmentVariable("LIFENARRATOR_DEBUG") == "1")
            Console.Error.WriteLine("[overlay] " + JsonSerializer.Serialize(new { action, bubble.Narration.Id,
                bubble.Narration.TrackID, bubble.Anchor, bubble.Frame, bubble.Line }, Protocol.Json));
    }

    void Leave(Bubble bubble)
    {
        Log("leave", bubble);
        // Drop the decoration at once; fade the narration at its current position.
        if (bubble.Highlight != null) bubble.Highlight.Opacity = 0;
        bubble.Dismissed = DateTimeOffset.UtcNow;
        bubble.Leaving = true;
    }

    public void DismissAll()
    {
        revision++;
        foreach (var bubble in bubbles) bubble.Dismissed = DateTimeOffset.UtcNow;
    }

    void Animate()
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var bubble in bubbles.ToArray())
        {
            if (bubble.Dismissed == null && (now - bubble.Born).TotalSeconds >= settings.Dwell) bubble.Dismissed = now;
            var opacity = bubble.Dismissed is { } dismissed
                ? 1 - (now - dismissed).TotalMilliseconds / 180
                : Math.Min(1, (now - bubble.Born).TotalMilliseconds / 180);
            if (opacity <= 0 && bubble.Dismissed != null) { Remove(bubble); continue; }
            bubble.Visual.Opacity = opacity;
            if (bubble.Highlight != null && !bubble.Leaving) bubble.Highlight.Opacity = opacity;
        }
    }

    void Remove(Bubble bubble)
    {
        bubble.Surface.Canvas.Children.Remove(bubble.Visual);
        if (bubble.Highlight != null) bubble.Surface.Canvas.Children.Remove(bubble.Highlight);
        bubbles.Remove(bubble);
        if (bubble.Narration.TrackID is { } id) Sensor.ReleaseTrack(id);
    }

    public void Dispose()
    {
        timer.Stop(); followTimer.Stop();
        foreach (var surface in surfaces) surface.Window.Close();
    }
}
