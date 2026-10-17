using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Styling;
using LifeNarrator.Windows;

internal static class BubbleChecks
{
    const string Output = "artifacts/bubbles";
    public static void Run()
    {
        CheckSettings(); CheckFonts(); CheckMotion(); CheckClicks(); OverlayAnimationChecks.Run();
        foreach (var background in new[] { "transparent", "light", "dark" })
        {
            Directory.CreateDirectory($"{Output}/{background}");
            foreach (var shape in BubbleStyle.Shapes)
            foreach (var theme in BubbleStyle.Themes)
            foreach (var size in BubbleStyle.Sizes)
            {
                var style = new BubbleStyle { Shape = shape, Theme = theme, Size = size, EmojiDensity = "many" };
                var bubble = new BubbleVisual("又要上班了！", "又要上班了！", ["😩", "☕"], "zh", style, "sharp", appTail: shape == "speech");
                var scene = new Canvas { Width = bubble.Width + 80, Height = bubble.Height + 80, Background = Background(background) };
                scene.Children.Add(bubble); Canvas.SetLeft(bubble, 40); Canvas.SetTop(bubble, 40);
                Capture(scene, $"{Output}/{background}/{shape}-{theme}-{size}.png");
            }
            foreach (var shape in BubbleStyle.Shapes) Capture(Anchored(shape, background), $"{Output}/{background}/anchored-{shape}.png");
            if (background == "transparent") continue;
            Application.Current!.RequestedThemeVariant = background == "dark" ? ThemeVariant.Dark : ThemeVariant.Light;
            var preview = new BubblePreview();
            Capture(preview, $"{Output}/preview-{background}.png");
            var before = preview.Children.Last();
            preview.Style = new BubbleStyle { Shape = "note", Theme = "candy", Size = "medium", TextEffects = TextEffects.Gradient, EmojiDensity = "many" };
            if (ReferenceEquals(before, preview.Children.Last()) || ((BubbleVisual)preview.Children.Last()).Style.Shape != "note")
                throw new Exception("Preview did not redraw after a style change");
            Capture(preview, $"{Output}/preview-changed-{background}.png");
            foreach (var effects in new[] { TextEffects.None, TextEffects.Outline, TextEffects.Shadow, TextEffects.Gradient, TextEffects.Outline | TextEffects.Shadow | TextEffects.Gradient })
            {
                var bubble = new BubbleVisual("effects", "Art text 文字", ["✨", "🐱"], "zh",
                    new BubbleStyle { Size = "medium", TextEffects = effects, EmojiDensity = "many" });
                var scene = new Canvas { Width = 400, Height = 160, Background = Background(background) };
                Canvas.SetLeft(bubble, 30); Canvas.SetTop(bubble, 40); scene.Children.Add(bubble);
                Capture(scene, $"{Output}/effects-{(int)effects}-{background}.png");
            }
        }
        Console.WriteLine("PASS: 399 bubble/anchor snapshots (transparent/light/dark); text effects; seven-shape click delivery; preview redraw; font fallback chains; migration, locks, emoji, dwell and animation checks");
    }

    static void CheckClicks()
    {
        foreach (var shape in BubbleStyle.Shapes)
        {
            var bubble = new BubbleVisual("click", "Click me", [], "en", new BubbleStyle { Shape = shape });
            var window = new Window { Width = bubble.Width, Height = bubble.Height, Content = bubble };
            var clicks = 0;
            bubble.PointerReleased += (_, e) => { if (e.InitialPressMouseButton == MouseButton.Left) clicks++; };
            window.Show();
            using var frame = window.CaptureRenderedFrame();
            var center = new Point(bubble.Width / 2, bubble.Height / 2);
            window.MouseDown(center, MouseButton.Left); window.MouseUp(center, MouseButton.Left);
            if (clicks != 1) throw new Exception("Bubble click did not reach chat/dismiss handler: " + shape);
            window.Close();
        }
    }

    static void CheckFonts()
    {
        foreach (var (choice, families, weight) in new (string, string[], FontWeight)[]
        {
            ("hannotate", ["KaiTi", "楷体"], FontWeight.Normal),
            ("hanzipen", ["KaiTi", "楷体"], FontWeight.Normal),
            ("yuanti", ["DengXian", "等线"], FontWeight.Normal),
            ("wawati", ["Microsoft YaHei UI"], FontWeight.Bold),
            ("noteworthy", ["Segoe Print"], FontWeight.Normal),
            ("chalkboard", ["Comic Sans MS"], FontWeight.Normal),
            ("markerFelt", ["Ink Free"], FontWeight.Normal)
        })
        {
            var font = BubbleFonts.Typeface(choice, "gentle", "zh");
            if (!font.FontFamily.FamilyNames.Take(families.Length).SequenceEqual(families)
                || font.FontFamily.FamilyNames.Last() != "Microsoft YaHei UI" || font.Weight != weight)
                throw new Exception("Localized font fallback chain/weight failed: " + choice);
        }
        var chinese = BubbleFonts.Typeface("persona", "chuuni", "zh");
        var english = BubbleFonts.Typeface("persona", "chuuni", "en");
        if (chinese.FontFamily.Name != "Microsoft YaHei UI" || chinese.Weight != FontWeight.Bold
            || english.FontFamily.Name != "Ink Free" || english.Weight != FontWeight.Normal)
            throw new Exception("Persona font/weight did not follow the language-specific chain");
    }

    static void CheckSettings()
    {
        var defaults = new Settings().ActiveStyle(null);
        if (defaults != new BubbleStyle()) throw new Exception("Windows defaults differ from Mac BubbleStyle");
        var old = JsonSerializer.Deserialize<Settings>("{\"bubbleShape\":\"automatic\",\"bubbleTheme\":\"random\"}", Protocol.Json)!;
        if (old.BubbleShape != "text" || old.BubbleTheme != "random") throw new Exception("Legacy appearance migration failed");
        var settings = new Settings { BubbleShape = "cloud", BubbleSize = "large", BubbleTheme = "candy", BubbleFont = "markerFelt",
            BubbleOutline = false, BubbleShadow = false, BubbleGradient = true, BubbleAnimation = "pop", EmojiDensity = "many", BubblePersistent = true };
        var restored = JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(settings, Protocol.Json), Protocol.Json)!;
        if (restored.ActiveStyle(null) != settings.ActiveStyle(null) || restored.ActiveStyle(null).Dwell != null)
            throw new Exception("Appearance persistence/resident dwell failed");
        if (new BubbleStyle().DisplayedEmoji(["a", "b"]).Length != 1
            || (new BubbleStyle { EmojiDensity = "none", Emoji = "🌟" }).DisplayedEmoji(["a"]).Length != 0
            || (new BubbleStyle { EmojiDensity = "many" }).DisplayedEmoji(["a", "b"]).Length != 2
            || !(new BubbleStyle { Emoji = "🌟" }).DisplayedEmoji(["a"]).SequenceEqual(["🌟"]))
            throw new Exception("Emoji density/selection failed");
        if ((new BubbleStyle { Dwell = 3, MaxOnScreen = 5 }).EffectiveDwell != 12.5
            || (new BubbleStyle { Dwell = null, MaxOnScreen = 5 }).EffectiveDwell != null)
            throw new Exception("Extended dwell or resident expiry failed");
        foreach (var level in new[] { 1, 3, 5, 15 })
        {
            var unlocks = new[] { ("emoji", 3), ("starBubble", 5), ("starryTheme", 15) }.Where(u => u.Item2 <= level).Select(u => u.Item1).ToArray();
            var growth = new GrowthInfo(new GrowthNumbers(level, 0, 0, 0, 0, 0, 0, unlocks), "", "", null, 0, []);
            var active = new Settings { BubbleShape = "star", BubbleTheme = "starry", Emoji = "🌟" }.ActiveStyle(growth);
            if ((active.Shape == "star") != (level >= 5) || (active.Theme == "starry") != (level >= 15) || (active.Emoji != null) != (level >= 3))
                throw new Exception("Mac growth levels not enforced");
        }
        foreach (var appLevel in new[] { false, true })
        {
            var json = JsonSerializer.SerializeToElement(new Dictionary<string, object>
            {
                ["frame"] = new { x = 0, y = 0, w = 200, h = 40 }, ["narrow"] = false, ["covered"] = false,
                ["connector"] = !appLevel, ["outside"] = false, ["placement"] = appLevel ? "corner" : "above",
                [appLevel ? "corner" : "side"] = appLevel ? "topRight" : "above"
            });
            var placement = Placement.Read(json);
            if (appLevel ? placement.Side != null || placement.Corner != "topRight" : placement.Side != "above" || placement.Corner != null)
                throw new Exception("Optional Swift placement fields did not decode");
        }
        if (BubbleStyle.StableHash("hello") != 0xa430d84680aabd0bUL)
            throw new Exception("UTF8 stable hash failed");
    }

    static void CheckMotion()
    {
        foreach (var animation in BubbleStyle.Animations)
        {
            var start = BubbleTransitions.Sample(animation, 0, false, new Vector(24, 0));
            var end = BubbleTransitions.Sample(animation, BubbleTransitions.EntranceDuration(animation), false, new Vector(24, 0));
            var exit = BubbleTransitions.Sample(animation, BubbleTransitions.ExitDuration(animation), true, new Vector(24, 0));
            if (start.Opacity != 0 || end.Opacity != 1 || end.Scale != 1 || end.Offset != default || exit.Opacity != 0)
                throw new Exception("Animation endpoints failed: " + animation);
            var reduced = BubbleTransitions.Sample(animation, 0, false, new Vector(24, 0), true);
            if (reduced.Scale != 1 || reduced.Offset != default) throw new Exception("Reduced motion still transforms");
        }
        if (BubbleTransitions.Sample("bounce", .21, false, default).Scale <= 1) throw new Exception("Bounce has no spring overshoot");
        if (BubbleTransitions.Slide(new Rect(800, 200, 100, 40), new Rect(0, 0, 920, 800)) != new Vector(24, 0))
            throw new Exception("Slide does not use nearest window edge");
    }

    static Canvas Anchored(string shape, string background)
    {
        var w = shape == "star" ? 520 : 360; var h = shape == "star" ? 420 : 220;
        var scene = new Canvas { Width = w, Height = h, Background = background == "transparent" ? Brushes.White : Background(background) };
        var highlight = new Rect(w / 2d - 35, h - 53, 58, 26);
        var bubble = new BubbleVisual("Pig Boss incoming", "Pig Boss incoming", ["😩", "☕"], "en",
            new BubbleStyle { Shape = shape, Size = "medium", EmojiDensity = "many" }, "sharp");
        // This fixture has no space beside or below the target; Mac placement chooses above.
        var frame = new Rect(Math.Clamp(highlight.Center.X - bubble.Width / 2, 8, w - 8 - bubble.Width), highlight.Top - 4 - bubble.Height, bubble.Width, bubble.Height);
        var decor = new AnchorDecor { Width = w, Height = h, Highlight = highlight, BubbleFrame = frame,
            Shape = shape, Size = "medium", Group = bubble.Group, Side = "above", Framed = true, Connector = true };
        scene.Children.Add(decor);
        if (shape == "speech") bubble.SetAnchoredTail(frame, highlight, "above");
        scene.Children.Add(bubble); Canvas.SetLeft(bubble, frame.X); Canvas.SetTop(bubble, frame.Y);
        return scene;
    }

    static IBrush Background(string background) => background switch
    { "dark" => Brush.Parse("#1E1E1E"), "light" => Brushes.White, _ => Brushes.Transparent };

    static void Capture(Control control, string path)
    {
        var window = new Window { Width = control.Width, Height = control.Height, Content = control, Background = Brushes.Transparent,
            TransparencyLevelHint = [WindowTransparencyLevel.Transparent] };
        window.Show(); window.UpdateLayout();
        using var frame = window.CaptureRenderedFrame() ?? throw new Exception("No bubble pixels: " + path);
        using var pixels = frame.Lock();
        var bytes = new byte[pixels.RowBytes * pixels.Size.Height]; Marshal.Copy(pixels.Address, bytes, 0, bytes.Length);
        if (path.Contains("/transparent/") && !Path.GetFileName(path).StartsWith("anchored-") && bytes[3] != 0)
            throw new Exception("Transparent snapshot has an opaque background: " + path);
        if (bytes.All(b => b == 0)) throw new Exception("Empty bubble snapshot: " + path);
        if (path.EndsWith("/rounded-clear-small.png"))
        {
            var index = 45 * pixels.RowBytes + (pixels.Size.Width / 2) * 4;
            if (bytes[index + 3] < 250 || Math.Max(bytes[index], bytes[index + 2]) < 240 || bytes[index + 1] < 180)
                throw new Exception("Rounded fill is not aligned with its text/padding box: " + path + " pixel=" + string.Join(",", bytes.Skip(index).Take(4)));
        }
        // Avalonia Headless 11 returns premultiplied pixels labelled Opaque; preserve their alpha in PNGs.
        using var png = new WriteableBitmap(pixels.Format, AlphaFormat.Premul, pixels.Address, pixels.Size, pixels.Dpi, pixels.RowBytes);
        png.Save(path); window.Content = null; window.Close();
    }
}
