using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Rendering;
using LifeNarrator.Windows;

internal static class OverlayAnimationChecks
{
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static readonly Type Controller = typeof(OverlayController);
    static void Set(object target, string name, object? value) => target.GetType().GetField(name, Instance)!.SetValue(target, value);
    static object? Get(object target, string name) => target.GetType().GetField(name, Instance)!.GetValue(target);
    static void Call(object target, string name, params object[] args) => target.GetType().GetMethod(name, Instance)!.Invoke(target, args);

    public static void Run()
    {
        foreach (var reduced in new[] { false, true })
        foreach (var animation in BubbleStyle.Animations)
            Check(animation, reduced);
        Console.WriteLine("PASS: real OverlayController Animate keeps settled frames clean; entrance/exit, moved anchors, reduced motion, hover, dwell and resident checks");
    }

    static void Check(string animation, bool reduced)
    {
        var canvas = new Canvas();
        var window = new Window { Width = 800, Height = 600, Content = canvas };
        var visual = new BubbleVisual("animation", "Still here", [], "en",
            new BubbleStyle { Animation = animation, Dwell = null });
        var frame = new Box(100, 100, visual.Width, visual.Height);
        var anchor = new Box(120, 220, 80, 25);
        var decor = new AnchorDecor { Width = 800, Height = 600, Framed = true, Group = visual.Group };
        canvas.Children.Add(decor); canvas.Children.Add(visual);
        var map = new DisplayMap(new PixelRect(0, 0, 800, 600), new PixelRect(0, 0, 800, 600), 1);
        var surfaceType = Controller.GetNestedType("Surface", BindingFlags.NonPublic)!;
        var surface = Activator.CreateInstance(surfaceType, Instance, null, [window, canvas, map], null)!;
        var geometry = new WindowGeometry(new Box(0, 0, 800, 600), 0);
        var narration = new Narration("test", "Still here", [], "en", "gentle", true, 1, geometry, anchor, null, [], "test", "test", 0);
        var placement = new Placement(frame, anchor, false, false, "above", null, "above", true, false, null);
        var bubbleType = Controller.GetNestedType("Bubble", BindingFlags.NonPublic)!;
        var bubble = Activator.CreateInstance(bubbleType, Instance, null, [narration, surface, visual, decor, frame, anchor, placement], null)!;
        // Bypass only the Windows constructor: exercise the production frame and position methods.
        var controller = (OverlayController)RuntimeHelpers.GetUninitializedObject(Controller);
        var surfaces = Array.CreateInstance(surfaceType, 1); surfaces.SetValue(surface, 0);
        Set(controller, "surfaces", surfaces);
        var bubbles = (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(bubbleType))!;
        bubbles.Add(bubble); Set(controller, "bubbles", bubbles);
        Set(controller, "colorIndices", new Dictionary<BubbleVisual, int>());
        Set(controller, "reduceMotion", reduced);
        Call(controller, "Position", bubble);
        Native.Cursor = new Native.CursorPoint { X = -100, Y = -100 };
        window.Show(); window.UpdateLayout();
        var renderer = ((IRenderRoot)window).Renderer;
        var dirtyField = renderer.GetType().GetField("_dirty", Instance)
            ?? throw new Exception("Avalonia renderer dirty set changed; update animation test observer");
        bool Dirty(Visual v) => ((IEnumerable)dirtyField.GetValue(renderer)!).Cast<object>().Contains(v);
        void Flush() { using var rendered = window.CaptureRenderedFrame(); }
        void Tick() => Call(controller, "Animate");
        void Age(double seconds) => Set(bubble, "Born", DateTimeOffset.UtcNow.AddSeconds(-seconds));
        void Require(bool condition, string message) { if (!condition) throw new Exception($"{animation}, reduced={reduced}: {message}"); }
        try
        {
            Age(10); Tick(); Flush();
            Require(visual.RenderTransform is MatrixTransform, "first frame did not install transform");
            var settled = visual.RenderTransform;
            for (var i = 0; i < 5; i++)
            {
                var reads = Native.CursorReads; Tick();
                Require(Native.CursorReads == reads + 1, "settled tick skipped cursor polling");
                Require(ReferenceEquals(settled, visual.RenderTransform), "settled tick replaced transform");
                Require(!Dirty(visual) && !Dirty(decor), "settled tick dirtied bubble or decoration");
                Require(Get(bubble, "Dismissed") == null, "resident bubble expired");
                Flush();
            }
            Native.Cursor = new Native.CursorPoint { X = 110, Y = 110 }; Tick();
            Require((bool)Get(surface, "Interactive")!, "hover did not enable interaction");
            Native.Cursor = new Native.CursorPoint { X = -100, Y = -100 }; Tick();
            Require(!(bool)Get(surface, "Interactive")!, "hover exit did not restore passthrough");
            Flush();

            // Position is also used after window moves and tracked scrolling.
            Set(bubble, "Anchor", anchor.Offset(15, 10));
            Set(bubble, "Frame", frame.Offset(15, 10));
            Call(controller, "Position", bubble);
            Require(decor.Highlight == anchor.Offset(15, 10).Rect && decor.BubbleFrame == frame.Offset(15, 10).Rect && Dirty(decor),
                "anchor/frame movement did not request decoration redraw");
            Flush(); Tick();
            Require(!Dirty(decor), "settled tick redrew moved decoration again");

            Age(.05); Tick(); Flush();
            var enteringOpacity = visual.Opacity;
            var enteringTransform = visual.RenderTransform;
            Age(.20); Tick();
            Require(visual.Opacity != enteringOpacity, "entrance opacity stopped updating");
            if (!reduced && animation != "slide")
                Require(!ReferenceEquals(enteringTransform, visual.RenderTransform), "entrance transform stopped updating");
            Require(reduced ? decor.Progress == 1 : Dirty(decor), "decoration entrance/reduced motion failed");
            Flush(); Age(10); Tick(); Flush();
            Set(bubble, "Dismissed", DateTimeOffset.UtcNow.AddSeconds(-.05)); Tick(); Flush();
            var exitingOpacity = visual.Opacity;
            var exitingTransform = visual.RenderTransform;
            Set(bubble, "Dismissed", DateTimeOffset.UtcNow.AddSeconds(-.10)); Tick();
            Require(visual.Opacity < exitingOpacity && decor.Opacity < 1, "exit fade stopped updating");
            if (!reduced && animation != "fade")
                Require(!ReferenceEquals(exitingTransform, visual.RenderTransform), "exit transform stopped updating");
            Set(bubble, "Dismissed", DateTimeOffset.UtcNow.AddSeconds(-1)); Tick();
            Require(bubbles.Count == 0 && !canvas.Children.Contains(visual) && !canvas.Children.Contains(decor), "exit did not remove controls");

            Set(bubble, "Dismissed", null); bubbles.Add(bubble);
            canvas.Children.Add(decor); canvas.Children.Add(visual);
            Call(controller, "Leave", bubble);
            Set(bubble, "Dismissed", DateTimeOffset.UtcNow.AddSeconds(-.10)); Tick();
            Require(decor.Opacity == 0 && visual.Opacity < 1, "lost anchor restored decoration or stopped narration fade");
            Set(bubble, "Dismissed", DateTimeOffset.UtcNow.AddSeconds(-1)); Tick();

            // Use the same live controller and actual expiry branch for a timed bubble.
            var timed = new BubbleVisual("dwell", "Time to go", [], "en", new BubbleStyle { Animation = animation, Dwell = 1 });
            var timedBubble = Activator.CreateInstance(bubbleType, Instance, null, [narration, surface, timed, null, frame, null, placement], null)!;
            Set(timedBubble, "Born", DateTimeOffset.UtcNow.AddSeconds(-10)); bubbles.Add(timedBubble); Tick();
            Require(Get(timedBubble, "Dismissed") != null, "dwell expiry stopped dismissing");
        }
        finally { window.Close(); }
    }
}

// Headless-only platform boundaries. Unexpected sensor access fails rather than simulating it.
namespace LifeNarrator.Windows
{
    internal static class Native
    {
        public struct CursorPoint { public int X, Y; }
        public static CursorPoint Cursor;
        public static int CursorReads;
        public const uint OverlayExtendedStyles = 0;
        public static bool GetCursorPos(out CursorPoint point) { CursorReads++; point = Cursor; return true; }
        public static void SetOverlayInteractive(nint handle, bool interactive) { }
        public static void ApplyOverlayStyles(nint handle) => throw new NotSupportedException();
        public static void EnableLayeredWindow(nint handle) => throw new NotSupportedException();
    }
    internal sealed class ContextSensor
    {
        internal record TrackSample(string Id, Box? Offset);
        public Task<TrackSample[]> ReadTracks(string[] ids) => throw new NotSupportedException();
        public void ReleaseTrack(string id) => throw new NotSupportedException();
    }
}
