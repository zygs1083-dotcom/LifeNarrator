using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;

namespace LifeNarrator.Windows;

internal sealed class OverlayController : IDisposable
{
    sealed record Surface(Window Window, Canvas Canvas, DisplayMap Map)
    {
        public bool Interactive;
    }
    sealed class Bubble(Narration narration, Surface surface, BubbleVisual visual, AnchorDecor? highlight, Box frame, Box? anchor, Placement placement)
    {
        public readonly Narration Narration = narration;
        public readonly Surface Surface = surface;
        public readonly BubbleVisual Visual = visual;
        public readonly AnchorDecor? Highlight = highlight;
        public readonly Placement Placement = placement;
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
    readonly bool reduceMotion;
    readonly double baseHue = Random.Shared.NextDouble() * 360;
    int randomIndex;
    readonly List<(string Theme, int Index)> recentGroups = [];
    readonly Dictionary<BubbleVisual, int> colorIndices = [];
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfoW(uint action, uint parameter, out int value, uint flags);
    readonly Companion companion;
    readonly Action<string, PixelPoint> openChat;
    readonly DispatcherTimer timer;
    readonly DispatcherTimer followTimer = null!;
    readonly Action<string> failed;
    public ContextSensor Sensor { private get; set; } = null!;
    DateTimeOffset followUntil;
    readonly SemaphoreSlim followGate = new(1);
    int revision;
    public bool HasShown { get; private set; }
    public DisplayMap[] Displays => surfaces.Select(x => x.Map).ToArray();

    public OverlayController(Settings settings, Action<string> failed, Companion companion, Action<string, PixelPoint> openChat)
    {
        if (!SystemParametersInfoW(0x1042, 0, out var animations, 0)) throw new System.ComponentModel.Win32Exception();
        reduceMotion = animations == 0;
        this.settings = settings; this.failed = failed; this.companion = companion; this.openChat = openChat;
        var probe = new Window();
        surfaces = probe.Screens.All.Select(screen =>
        {
            var canvas = new Canvas { ClipToBounds = true };
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
            if (followGate.CurrentCount == 0) return;
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
            var style = settings.ActiveStyle(companion.Growth);
            var tierResult = await brain.Call("layout.sizeTier", new { requested = style.Size, window = narration.Window });
            if (tierResult.ValueKind == JsonValueKind.Null) return new { shown = false, placement = "none" };
            var tier = tierResult.GetString()!;
            var surface = surfaces.FirstOrDefault(x => x.Map.Logical(x.Map.Bounds).Rect.Contains(narration.Window.Frame.Rect.Center)) ?? surfaces[0];
            style = style with { Size = tier };
            var (group, groupIndex) = SelectColor(style, narration.Id);
            var fillOpacity = 1d;
            var visual = MakeVisual(false);
            var narrow = MakeVisual(true);
            Placement? placement = await Place(visual, narrow);
            if (placement?.Covered == true && style.Shape != "text")
            {
                style = style with { Shape = "rounded" };
                fillOpacity = .92;
                visual = MakeVisual(false); narrow = MakeVisual(true);
            }
            if (placement == null || currentRevision != revision || settings.Paused) return new { shown = false, placement = "none" };
            var stack = bubbles.Where(x => x.Dismissed == null && x.Narration.WindowID == narration.WindowID && x.Narration.Anchor == null).Reverse().ToArray();
            if (placement.StackFrames != null)
                for (var i = 0; i < stack.Length; i++)
                {
                    var frame = placement.StackFrames[i + 1];
                    if (frame == null) Dismiss(stack[i]);
                    else { stack[i].Frame = frame; Position(stack[i]); }
                }
            while (bubbles.Count(x => x.Dismissed == null) >= settings.MaxOnScreen)
                Dismiss(bubbles.First(x => x.Dismissed == null));
            visual = placement.Narrow ? narrow : visual;
            placement = placement with { Frame = placement.Frame with { W = visual.Width, H = visual.Height } };
            var highlight = placement.Highlight != null && (narration.Framed || placement.Outside) ? new AnchorDecor
            {
                Width = surface.Window.Width, Height = surface.Window.Height, IsHitTestVisible = false,
                Side = placement.Side!, Shape = visual.Style.Shape, Size = visual.Style.Size, Group = group,
                Connector = placement.Connector, Outside = placement.Outside, Framed = narration.Framed
            } : null;
            var bubble = new Bubble(narration, surface, visual, highlight, placement.Frame, placement.Highlight, placement);
            if (groupIndex is { } index) colorIndices.Add(visual, index);
            visual.PointerReleased += (_, e) =>
            {
                if (e.InitialPressMouseButton != Avalonia.Input.MouseButton.Left) return;
                var position = surface.Map.Physical(bubble.Frame);
                openChat(narration.Text, new PixelPoint((int)(position.X + position.W), (int)position.Y));
                if (bubble.Visual.Style.Dwell == null) Dismiss(bubble);
                e.Handled = true;
            };
            visual.Opacity = 0;
            if (highlight != null) { highlight.Opacity = 0; surface.Canvas.Children.Add(highlight); }
            surface.Canvas.Children.Add(visual);
            bubbles.Add(bubble);
            retained = true;
            Position(bubble);
            await Follow(); // Catch scrolling during model generation before the first visible frame.
            Log("show", bubble);
            HasShown |= bubbles.Contains(bubble) && bubble.Dismissed == null;
            return new { shown = bubbles.Contains(bubble) && bubble.Dismissed == null, placement = placement.PlacementName };

            BubbleVisual MakeVisual(bool small) => new(narration.Id, narration.Text, narration.Emoji,
                narration.Language, small ? style with { Size = "small" } : style, narration.Persona, small,
                fillOpacity, narration.Anchor == null && style.Shape == "speech", group);
            async Task<Placement?> Place(BubbleVisual normal, BubbleVisual small)
            {
                var existing = bubbles.Where(x => x.Dismissed == null && x.Narration.WindowID == narration.WindowID).ToArray();
                var result = await brain.Call("layout.place", new
                {
                    size = new Dimensions(normal.Width, normal.Height), narrowSize = new Dimensions(small.Width, small.Height),
                    narration.Anchor, narration.Line, narration.Window,
                    visibleFrame = surface.Map.Logical(surface.Map.WorkArea),
                    occupied = existing.SelectMany(x => x.Anchor == null ? new[] { x.Frame } : new[] { x.Frame, x.Anchor }).ToArray(),
                    obstacles = narration.Obstacles, inkInset = style.Shape == "text" ? new Dimensions(new BubbleMetrics(style.Size).HorizontalPadding, new BubbleMetrics(style.Size).VerticalPadding) : new Dimensions(0, 0),
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

    (BubbleColors Group, int? Index) SelectColor(BubbleStyle style, string id)
    {
        if (style.Theme == "random") return (BubbleColors.Random(baseHue, randomIndex++), null);
        var palette = BubbleColors.Palette(style.Theme);
        var occupied = bubbles.Where(b => b.Dismissed == null && b.Visual.Style.Theme == style.Theme)
            .Select(b => colorIndices[b.Visual]).ToHashSet();
        int index;
        if (settings.Liveliness == "quiet")
        {
            index = (int)(BubbleStyle.StableHash(id) % (ulong)palette.Length);
            if (occupied.Contains(index)) index = (index + 1) % palette.Length;
        }
        else
        {
            var recent = recentGroups.Where(g => g.Theme == style.Theme).TakeLast(style.Theme == "clear" ? 2 : 1).Select(g => g.Index).ToHashSet();
            var choices = Enumerable.Range(0, palette.Length).Where(i => !occupied.Contains(i) && !recent.Contains(i)
                && (style.Theme != "clear" || !occupied.Any(other =>
                {
                    var delta = Math.Abs(BubbleColors.ClearHues[i] - BubbleColors.ClearHues[other]);
                    return Math.Min(delta, 360 - delta) < 45;
                }))).ToArray();
            if (choices.Length == 0) choices = Enumerable.Range(0, palette.Length).Where(i => !occupied.Contains(i)).ToArray();
            if (choices.Length == 0) choices = Enumerable.Range(0, palette.Length).ToArray();
            index = choices[Random.Shared.Next(choices.Length)];
            recentGroups.Add((style.Theme, index));
            if (recentGroups.Count > 2) recentGroups.RemoveAt(0);
        }
        return (palette[index], index);
    }

    void Position(Bubble bubble)
    {
        var map = bubble.Surface.Map;
        Canvas.SetLeft(bubble.Visual, bubble.Frame.X - map.Bounds.X);
        Canvas.SetTop(bubble.Visual, bubble.Frame.Y - map.Bounds.Y);
        if (bubble.Highlight != null && bubble.Anchor is { } anchor)
        {
            bubble.Highlight.Highlight = anchor.Rect.Translate(new Vector(-map.Bounds.X, -map.Bounds.Y));
            bubble.Highlight.BubbleFrame = bubble.Frame.Rect.Translate(new Vector(-map.Bounds.X, -map.Bounds.Y));
            bubble.Highlight.InvalidateVisual();
        }
        if (bubble.Visual.Style.Shape == "speech")
        {
            if (bubble.Anchor is { } target && bubble.Narration.Framed && bubble.Placement.Connector && !bubble.Placement.Covered && !bubble.Placement.Outside)
                bubble.Visual.SetAnchoredTail(bubble.Frame.Rect, target.Rect, bubble.Placement.Side!);
            else if (bubble.Anchor == null) bubble.Visual.SetAppTail(bubble.Placement.Corner!);
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
        await followGate.WaitAsync();
        try
        {
            var active = bubbles.Where(x => x.Dismissed == null && x.Narration.TrackID != null).ToArray();
            if (active.Length == 0) return;
            var currentRevision = revision;
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
        finally { followGate.Release(); }
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
        Dismiss(bubble);
        bubble.Leaving = true;
    }

    public void DismissAll()
    {
        revision++;
        foreach (var bubble in bubbles) Dismiss(bubble);
    }

    void Animate()
    {
        if (!Native.GetCursorPos(out var cursor)) throw new System.ComponentModel.Win32Exception();
        foreach (var surface in surfaces)
        {
            var point = surface.Map.Logical(new Box(cursor.X, cursor.Y, 0, 0)).Rect.Position;
            var interactive = bubbles.Any(b => b.Surface == surface && b.Dismissed == null && b.Frame.Rect.Contains(point));
            if (interactive != surface.Interactive)
            { Native.SetOverlayInteractive(surface.Window.TryGetPlatformHandle()!.Handle, interactive); surface.Interactive = interactive; }
        }
        var now = DateTimeOffset.UtcNow;
        foreach (var bubble in bubbles.ToArray())
        {
            var animation = reduceMotion ? "fade" : bubble.Visual.Style.Animation;
            var delay = bubble.Anchor == null || !bubble.Narration.Framed ? 0 : .12;
            var age = (now - bubble.Born).TotalSeconds;
            if (bubble.Visual.Style.EffectiveDwell is { } dwell && bubble.Dismissed == null && age >= delay + BubbleTransitions.EntranceDuration(animation) + dwell)
                Dismiss(bubble);
            var elapsed = bubble.Dismissed is { } dismissed ? (now - dismissed).TotalSeconds : age - delay;
            if (bubble.Dismissed != null && elapsed >= Math.Max(BubbleTransitions.ExitDuration(animation), bubble.Highlight == null ? 0 : .6)) { Remove(bubble); continue; }
            var slide = BubbleTransitions.Slide(bubble.Frame.Rect, bubble.Window.Frame.Rect);
            var motion = BubbleTransitions.Sample(animation, elapsed, bubble.Dismissed != null, slide, reduceMotion);
            bubble.Visual.Opacity = motion.Opacity;
            var size = new Size(bubble.Visual.Width, bubble.Visual.Height);
            var origin = bubble.Visual.TailTip ?? (bubble.Placement.Side switch
            {
                "above" => new Point(size.Width / 2, size.Height), "below" => new Point(size.Width / 2, 0),
                "right" => new Point(0, size.Height / 2), "left" => new Point(size.Width, size.Height / 2),
                _ => new Point(bubble.Placement.Corner == "topRight" ? size.Width : 0, 0)
            });
            bubble.Visual.RenderTransformOrigin = new RelativePoint(0, 0, RelativeUnit.Absolute);
            bubble.Visual.RenderTransform = new MatrixTransform(Matrix.CreateTranslation(-origin.X, -origin.Y)
                * Matrix.CreateScale(motion.Scale, motion.Scale) * Matrix.CreateTranslation(origin.X + motion.Offset.X, origin.Y + motion.Offset.Y));
            if (bubble.Highlight != null && !bubble.Leaving)
            {
                bubble.Highlight.Progress = reduceMotion ? 1 : BubbleTransitions.DecorProgress(age);
                bubble.Highlight.Opacity = bubble.Dismissed is { } end ? BubbleTransitions.Sample("fade", (now - end).TotalSeconds, true, default).Opacity : 1;
                bubble.Highlight.InvalidateVisual();
            }
        }
    }

    static void Dismiss(Bubble bubble) => bubble.Dismissed ??= DateTimeOffset.UtcNow;

    void Remove(Bubble bubble)
    {
        bubble.Surface.Canvas.Children.Remove(bubble.Visual);
        if (bubble.Highlight != null) bubble.Surface.Canvas.Children.Remove(bubble.Highlight);
        bubbles.Remove(bubble);
        colorIndices.Remove(bubble.Visual);
        if (bubble.Narration.TrackID is { } id) Sensor.ReleaseTrack(id);
    }

    public void Dispose()
    {
        revision++;
        timer.Stop(); followTimer.Stop();
        bubbles.Clear();
        foreach (var surface in surfaces) surface.Window.Close();
    }
}
