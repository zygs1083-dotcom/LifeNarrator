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
        public WindowGeometry Window = narration.Window;
        public DateTimeOffset Born = DateTimeOffset.UtcNow;
        public DateTimeOffset? Dismissed;
    }
    readonly Surface[] surfaces;
    readonly List<Bubble> bubbles = [];
    readonly Settings settings;
    readonly DispatcherTimer timer;
    int revision;
    public DisplayMap[] Displays => surfaces.Select(x => x.Map).ToArray();

    public OverlayController(Settings settings)
    {
        this.settings = settings;
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
    }

    public async Task<object?> Call(string method, JsonElement parameters, BrainClient brain)
    {
        switch (method)
        {
            case "overlay.show": return await Show(parameters.GetProperty("narration").Read<Narration>(), brain);
            case "overlay.dismissAll": DismissAll(); return null;
            case "overlay.follow": return null;
            case "overlay.highlight": return bubbles.Find(x => x.Narration.Id == parameters.GetProperty("id").GetString() && x.Dismissed == null)?.Anchor;
            case "overlay.windowFrameChanged":
                Move(parameters.GetProperty("windowID").GetUInt32(), parameters.GetProperty("window").Read<WindowGeometry>()); return null;
            default: throw new MissingMethodException(method);
        }
    }

    async Task<object> Show(Narration narration, BrainClient brain)
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
            narration.Framed ? placement.Highlight : null);
        visual.Opacity = 0;
        if (highlight != null) { highlight.Opacity = 0; surface.Canvas.Children.Add(highlight); }
        surface.Canvas.Children.Add(visual);
        bubbles.Add(bubble);
        Position(bubble);
        return new { shown = true, placement = placement.PlacementName };

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
            bubble.Frame = bubble.Frame.Offset(dx, dy);
            bubble.Anchor = bubble.Anchor?.Offset(dx, dy);
            bubble.Window = window;
            Position(bubble);
        }
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
            if (bubble.Highlight != null) bubble.Highlight.Opacity = opacity;
        }
    }

    void Remove(Bubble bubble)
    {
        bubble.Surface.Canvas.Children.Remove(bubble.Visual);
        if (bubble.Highlight != null) bubble.Surface.Canvas.Children.Remove(bubble.Highlight);
        bubbles.Remove(bubble);
    }

    public void Dispose()
    {
        timer.Stop();
        foreach (var surface in surfaces) surface.Window.Close();
    }
}
