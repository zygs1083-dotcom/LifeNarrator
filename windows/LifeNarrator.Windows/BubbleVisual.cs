using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace LifeNarrator.Windows;

public sealed class BubbleVisual : Panel
{
    sealed class Paint(Action<DrawingContext> draw) : Control
    {
        public override void Render(DrawingContext context) => draw(context);
    }
    readonly FormattedText text, emoji;
    readonly BubbleMetrics metrics;
    readonly Size contentSize;
    readonly Point contentOrigin;
    readonly double rotation, fillOpacity;
        Geometry body;
    Geometry lettering;
    public BubbleStyle Style { get; }
    internal BubbleColors Group { get; }
    internal Point? TailTip { get; private set; }

    public BubbleVisual(string id, string caption, string[] emojis, string language, BubbleStyle style,
        string persona = "gentle", bool narrow = false, double fillOpacity = 1, bool appTail = false)
        : this(id, caption, emojis, language, style, persona, narrow, fillOpacity, appTail,
            style.Theme == "random" ? BubbleColors.Random(200, 0) : BubbleColors.Palette(style.Theme)[0]) { }

    internal BubbleVisual(string id, string caption, string[] emojis, string language, BubbleStyle style,
        string persona, bool narrow, double fillOpacity, bool appTail, BubbleColors colors)
    {
        Background = Brushes.Transparent;
        Style = style; Group = colors; this.fillOpacity = fillOpacity;
        metrics = new(style.Size);
        rotation = style.Shape switch
        {
            "sticker" => (int)(BubbleStyle.StableHash(id) % 7) - 3,
            "note" => (int)(BubbleStyle.StableHash(id) % 9) - 4, _ => 0
        };
        var shownEmoji = style.DisplayedEmoji(emojis);
        emoji = new FormattedText(string.Join("", shownEmoji), CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface("Segoe UI Emoji, Noto Color Emoji"), metrics.EmojiSize, Brushes.Black);
        var hp = metrics.HorizontalPadding + (style.Shape == "note" ? 2 : 0);
        var vp = metrics.VerticalPadding + (style.Shape == "note" ? 4 : 0);
        var gap = shownEmoji.Length == 0 ? 0 : 6;
        var width = narrow ? 160 : metrics.MaxWidth;
        if (style.Shape == "star") width /= 2;
        text = new FormattedText(caption, CultureInfo.GetCultureInfo(language == "zh" ? "zh-CN" : "en-US"),
            FlowDirection.LeftToRight, BubbleFonts.Typeface(style.Font, persona, language), metrics.FontSize, Brushes.Black)
        {
            MaxTextWidth = Math.Max(1, width - 2 * hp - gap - emoji.Width), MaxLineCount = 3,
            LineHeight = metrics.FontSize * 1.2 + metrics.LineSpacing, Trimming = TextTrimming.CharacterEllipsis
        };
        var textY = Math.Max(0, emoji.Baseline - text.Baseline);
        var emojiY = textY + text.Height - text.LineHeight + text.Baseline - emoji.Baseline;
        contentSize = new Size(Math.Ceiling((text.Width + gap + emoji.Width + 2 * hp) * 2) / 2,
            Math.Ceiling((Math.Max(textY + text.Height, emojiY + emoji.Height) + 2 * vp) * 2) / 2);
        var w = contentSize.Width; var h = contentSize.Height;
        (Width, Height, contentOrigin) = style.Shape switch
        {
            "cloud" => (w + .5 * h, 1.9 * h, new Point(.25 * h, .45 * h)),
            "sticker" => (w + 2 * metrics.PaperInset, h + 2 * metrics.PaperInset, new Point(metrics.PaperInset, metrics.PaperInset)),
            "note" => (Math.Max(w, 2.2 * (metrics.FontSize + metrics.LineSpacing)), h + 8,
                new Point((Math.Max(w, 2.2 * (metrics.FontSize + metrics.LineSpacing)) - w) / 2, 8)),
            "star" => (2 * w, 2.8 * h, new Point(w / 2, .9 * h)),
            "speech" => (w, h + (appTail ? metrics.TailHeight : 0), new Point()),
            _ => (w, h, new Point())
        };
        lettering = text.BuildGeometry(new Point(contentOrigin.X + hp, contentOrigin.Y + vp + textY))!;
        EmojiOrigin = new Point(contentOrigin.X + hp + text.Width + gap, contentOrigin.Y + vp + emojiY);
        body = MakeBody();
        if (style.Shape == "speech" && appTail) SetAppTail("topRight"); else Rebuild();
    }
    Point EmojiOrigin { get; }

    internal void SetAppTail(string corner)
    {
        var root = (corner == "topRight" ? .75 : .25) * contentSize.Width;
        TailTip = new Point(root + (corner == "topRight" ? -6 : 6), contentSize.Height + metrics.TailHeight);
        body = Speech("bottom", root, TailTip.Value); Rebuild();
    }

    internal void SetAnchoredTail(Rect frame, Rect highlight, string side)
    {
        var (edge, tip) = side switch
        {
            "above" => ("bottom", new Point(highlight.Center.X, highlight.Top - 2)),
            "below" => ("top", new Point(highlight.Center.X, highlight.Bottom + 2)),
            "right" => ("left", new Point(highlight.Right + 2, highlight.Center.Y)),
            _ => ("right", new Point(highlight.Left - 2, highlight.Center.Y))
        };
        var horizontal = side is "above" or "below";
        var margin = metrics.SpeechRadius + metrics.TailBase / 2;
        var root = Math.Clamp(horizontal ? highlight.Center.X - frame.X : highlight.Center.Y - frame.Y,
            margin, Math.Max(margin, (horizontal ? contentSize.Width : contentSize.Height) - margin));
        TailTip = tip - frame.Position;
        body = Speech(edge, root, TailTip.Value); Rebuild();
    }

    Geometry MakeBody()
    {
        var r = new Rect(0, 0, Width, Height);
        return Style.Shape switch
        {
            "text" => new StreamGeometry(),
            "rounded" => new RectangleGeometry(r, Math.Min(Height / 2, metrics.RoundedRadius), Math.Min(Height / 2, metrics.RoundedRadius)),
            "speech" => new RectangleGeometry(new Rect(contentSize), metrics.SpeechRadius, metrics.SpeechRadius),
            "sticker" => new RectangleGeometry(r, metrics.StickerRadius + metrics.PaperInset, metrics.StickerRadius + metrics.PaperInset),
            "note" => new RectangleGeometry(r, 2, 2),
            "cloud" => Cloud(r),
            "star" => Star(r),
            _ => throw new ArgumentOutOfRangeException(nameof(Style.Shape))
        };
    }

    void Rebuild()
    {
        Children.Clear();
        if (Style.Shape != "text")
        {
            if (Style.Theme == "neon" && Style.Shape is "rounded" or "speech" or "cloud" or "sticker")
            {
                var strokeWidth = Style.Shape == "cloud" ? 2 * metrics.StrokeWidth : metrics.StrokeWidth;
                Add(c => c.DrawGeometry(null, new Pen(new SolidColorBrush(Group.Stroke, .7), strokeWidth), body), 8);
                Add(c => c.DrawGeometry(null, new Pen(new SolidColorBrush(Group.Stroke, .7), strokeWidth), body), 3);
            }
            Add(DrawBody);
            Children[^1].Effect = new DropShadowEffect
            {
                Color = Colors.Black, Opacity = Style.Shape == "note" ? .20 : .22,
                BlurRadius = BubbleMetrics.BlurRadius(Style.Shape == "note" ? 4 : 8), OffsetX = 0, OffsetY = Style.Shape == "note" ? 2 : 3
            };
        }
        var neon = Style.Theme == "neon";
        var textOnly = Style.Shape == "text" && !neon;
        var ink = textOnly ? Group.Fill : Group.Text;
        var outline = neon ? Color.Parse("#141430") : textOnly ? Group.Text : Group.Stroke;
        var outlineWidth = Math.Max(1, .07 * metrics.FontSize);
        void Letters(DrawingContext c, IBrush brush, bool outlineOn)
        {
            if (outlineOn)
                foreach (var v in new[] { new Vector(outlineWidth, 0), new Vector(-outlineWidth, 0), new Vector(0, outlineWidth), new Vector(0, -outlineWidth),
                    new Vector(.71 * outlineWidth, .71 * outlineWidth), new Vector(-.71 * outlineWidth, .71 * outlineWidth),
                    new Vector(.71 * outlineWidth, -.71 * outlineWidth), new Vector(-.71 * outlineWidth, -.71 * outlineWidth) })
                {
                    using var shift = c.PushTransform(Matrix.CreateTranslation(v));
                    c.DrawGeometry(brush, null, lettering);
                }
            c.DrawGeometry(brush, null, lettering);
        }
        var hasOutline = Style.TextEffects.HasFlag(TextEffects.Outline);
        if (textOnly) Add(c => Letters(c, new SolidColorBrush(Colors.Black, .35), hasOutline), 2);
        if (Style.TextEffects.HasFlag(TextEffects.Shadow))
            Add(c => Letters(c, new SolidColorBrush(Colors.Black, neon ? .45 : .25), hasOutline), 0, new Vector(.06 * metrics.FontSize, .10 * metrics.FontSize));
        if (neon)
        {
            Add(c => Letters(c, new SolidColorBrush(ink, .8), hasOutline), .35 * metrics.FontSize);
            Add(c => Letters(c, new SolidColorBrush(ink, .8), hasOutline), .18 * metrics.FontSize);
        }
        Add(c =>
        {
            if (hasOutline) Letters(c, new SolidColorBrush(outline), true);
            IBrush brush = new SolidColorBrush(ink);
            if (Style.TextEffects.HasFlag(TextEffects.Gradient))
                brush = new LinearGradientBrush
                {
                    StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                    GradientStops = [new GradientStop(neon ? ink : BubbleColors.WhiteMix(ink, .35), 0),
                        new GradientStop(neon ? BubbleColors.WhiteMix(ink, .40) : ink, 1)]
                };
            c.DrawGeometry(brush, null, lettering);
            c.DrawText(emoji, EmojiOrigin);
        });
        if (Style.Shape == "note")
            Children.Add(new Paint(c =>
            {
                using var turn = c.PushTransform(Matrix.CreateRotation(-6 * Math.PI / 180, new Point(Width / 2, -3)));
                c.DrawRectangle(new SolidColorBrush(Colors.White, .55), null,
                    new Rect(Width / 2 - metrics.TapeWidth / 2, -3 - metrics.TapeHeight / 2, metrics.TapeWidth, metrics.TapeHeight));
            }));
        InvalidateMeasure();
    }

    void Add(Action<DrawingContext> draw, double blur = 0, Vector offset = default)
    {
        Children.Add(new Paint(c =>
        {
            using var turn = c.PushTransform(Matrix.CreateRotation(rotation * Math.PI / 180, new Point(Width / 2, Height / 2)) * Matrix.CreateTranslation(offset));
            draw(c);
        }) { Effect = blur > 0 ? new BlurEffect { Radius = BubbleMetrics.BlurRadius(blur) } : null, IsHitTestVisible = false });
    }

    void DrawBody(DrawingContext c)
    {
        var fill = new SolidColorBrush(Group.Fill, fillOpacity);
        var pen = new Pen(new SolidColorBrush(Group.Stroke), metrics.StrokeWidth, lineJoin: PenLineJoin.Round);
        if (Style.Shape == "sticker")
        {
            c.DrawGeometry(Brushes.White, new Pen(new SolidColorBrush(Group.Stroke), 1.5), body);
            c.DrawRectangle(fill, null, new Rect(metrics.PaperInset, metrics.PaperInset, contentSize.Width, contentSize.Height), metrics.StickerRadius, metrics.StickerRadius);
        }
        else if (Style.Shape == "cloud")
        {
            c.DrawGeometry(null, new Pen(new SolidColorBrush(Group.Stroke), 2 * metrics.StrokeWidth), body);
            c.DrawGeometry(fill, null, body);
        }
        else c.DrawGeometry(fill, Style.Shape == "note" ? null : pen, body);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        foreach (var child in Children) child.Arrange(new Rect(finalSize));
        return finalSize;
    }

    static Geometry Star(Rect r)
    {
        var geometry = new StreamGeometry();
        using var p = geometry.Open();
        for (var i = 0; i < 10; i++)
        {
            var angle = i * Math.PI / 5 - Math.PI / 2;
            var radius = i % 2 == 0 ? 1 : .62;
            var pt = new Point(r.Center.X + Math.Cos(angle) * radius * r.Width / 2, r.Center.Y + Math.Sin(angle) * radius * r.Height / 2);
            if (i == 0) p.BeginFigure(pt, true); else p.LineTo(pt);
        }
        p.EndFigure(true); return geometry;
    }

    static Geometry Cloud(Rect r)
    {
        var h = r.Height; var w = r.Width;
        Geometry g = new RectangleGeometry(new Rect(.15 * h, .15 * h, w - .3 * h, .7 * h), .35 * h, .35 * h);
        void Circle(double x, double y, double radius) => g = new CombinedGeometry(GeometryCombineMode.Union, g,
            new EllipseGeometry(new Rect(x - radius, y - radius, 2 * radius, 2 * radius)));
        var n = Math.Max(3, (int)Math.Round(w / (.5 * h), MidpointRounding.AwayFromZero));
        var step = (w - .4 * h) / (n - 1);
        for (var i = 0; i < n; i++) Circle(.2 * h + step * i, .3 * h, (i % 2 == 0 ? .36 : .30) * h);
        for (var i = 0; i < n - 1; i++) Circle(.2 * h + step * (i + .5), .72 * h, .27 * h);
        Circle(.18 * h, .5 * h, .3 * h); Circle(w - .18 * h, .5 * h, .3 * h);
        return g;
    }

    Geometry Speech(string edge, double root, Point tip)
    {
        var w = contentSize.Width; var h = contentSize.Height; var r = metrics.SpeechRadius;
        var g = new StreamGeometry();
        using var p = g.Open();
        void Tail(string at, Point from, Point to)
        {
            if (edge != at) return;
            var inward = (to - from) * .25;
            p.LineTo(from);
            p.QuadraticBezierTo(new Point((from.X + tip.X) / 2 + inward.X, (from.Y + tip.Y) / 2 + inward.Y), tip);
            p.QuadraticBezierTo(new Point((tip.X + to.X) / 2 - inward.X, (tip.Y + to.Y) / 2 - inward.Y), to);
        }
        void Arc(Point to) => p.ArcTo(to, new Size(r, r), 0, false, SweepDirection.Clockwise);
        var b = metrics.TailBase / 2;
        p.BeginFigure(new Point(r, 0), true);
        Tail("top", new Point(root - b, 0), new Point(root + b, 0));
        p.LineTo(new Point(w - r, 0)); Arc(new Point(w, r));
        Tail("right", new Point(w, root - b), new Point(w, root + b));
        p.LineTo(new Point(w, h - r)); Arc(new Point(w - r, h));
        Tail("bottom", new Point(root + b, h), new Point(root - b, h));
        p.LineTo(new Point(r, h)); Arc(new Point(0, h - r));
        Tail("left", new Point(0, root + b), new Point(0, root - b));
        p.LineTo(new Point(0, r)); Arc(new Point(r, 0)); p.EndFigure(true);
        return g;
    }
}
