using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace LifeNarrator.Windows;

public sealed class BubbleVisual : Control
{
    readonly FormattedText text, emoji;
    readonly bool rounded;
    readonly string shape, theme;
    readonly IBrush soft, ink, stroke;
    public BubbleVisual(string id, string caption, string[] emojis, string language, string tier, bool rounded, bool narrow, double fillOpacity = 1, string shape = "automatic", string theme = "random")
    {
        this.rounded = rounded; this.shape = shape; this.theme = theme;
        uint hash = 2166136261;
        foreach (var c in id) hash = (hash ^ c) * 16777619;
        var hue = hash % 360;
        soft = Hue(hue, .22, 1);
        ((SolidColorBrush)soft).Opacity = fillOpacity;
        ink = Hue(hue, .78, .40);
        stroke = Hue(hue, .62, .96);
        if (theme == "starry")
        {
            soft = new SolidColorBrush(Color.Parse("#252D58"), fillOpacity);
            ink = Brush.Parse("#E4E9FF"); stroke = Brush.Parse("#9CAAE8");
        }
        var size = tier switch { "small" => 20, "medium" => 26, _ => 32 };
        text = new FormattedText(caption, CultureInfo.GetCultureInfo(language == "zh" ? "zh-CN" : "en-US"),
            FlowDirection.LeftToRight, new Typeface("Microsoft YaHei, Noto Sans CJK SC", FontStyle.Normal, FontWeight.Bold), size, ink)
            { MaxTextWidth = (narrow ? 180 : 310) / (shape == "star" ? 2 : 1) };
        emoji = new FormattedText(string.Join("", emojis), CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface("Segoe UI Emoji, Noto Color Emoji"), size, Brushes.Black);
        Width = text.Width + emoji.Width + 32;
        Height = Math.Max(text.Height, emoji.Height) + 24;
        if (shape == "star") { Width *= 2; Height *= 2.8; }
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);
        if (shape == "star")
        {
            var star = new StreamGeometry();
            using (var path = star.Open())
            {
                for (var i = 0; i < 10; i++)
                {
                    var angle = -Math.PI / 2 + i * Math.PI / 5;
                    var radius = i % 2 == 0 ? .49 : .3038;
                    var point = new Point(Width / 2 + Math.Cos(angle) * Width * radius,
                        Height / 2 + Math.Sin(angle) * Height * radius);
                    if (i == 0) path.BeginFigure(point, true); else path.LineTo(point);
                }
                path.EndFigure(true);
            }
            context.DrawGeometry(soft, new Pen(stroke, 1.3), star);
        }
        else if (rounded || theme == "starry")
        {
            context.DrawRectangle(new SolidColorBrush(Colors.Black, .12), null,
                new Rect(6, 8, Width - 10, Height - 10), 12, 12);
            context.DrawRectangle(soft, new Pen(stroke, 1.3), new Rect(4, 4, Width - 10, Height - 10), 12, 12);
        }
        if (theme == "starry")
            foreach (var point in new[] { new Point(10, 10), new Point(Width - 14, 12), new Point(Width - 20, Height - 14) })
                context.DrawEllipse(Brushes.LightGoldenrodYellow, null, point, 1.2, 1.2);
        using var shift = context.PushTransform(Matrix.CreateTranslation(shape == "star" ? Width / 4 : 0, shape == "star" ? Height * .9 / 2.8 : 0));
        var geometry = text.BuildGeometry(new Point(14, 10))!;
        using (context.PushTransform(Matrix.CreateTranslation(1.5, 2.5)))
            context.DrawGeometry(new SolidColorBrush(Colors.Black, .22), new Pen(new SolidColorBrush(Colors.Black, .15), 6), geometry);
        context.DrawGeometry(ink, new Pen(theme == "starry" ? soft : Brushes.White, 6), geometry);
        context.DrawGeometry(ink, new Pen(stroke, 1.4), geometry);
        context.DrawText(emoji, new Point(16 + text.Width, 10));
    }

    static IBrush Hue(double degrees, double saturation, double brightness)
    {
        var h = degrees / 60;
        var c = brightness * saturation;
        var x = c * (1 - Math.Abs(h % 2 - 1));
        var (r, g, b) = h switch
        {
            < 1 => (c, x, 0d), < 2 => (x, c, 0d), < 3 => (0d, c, x),
            < 4 => (0d, x, c), < 5 => (x, 0d, c), _ => (c, 0d, x)
        };
        var m = brightness - c;
        return new SolidColorBrush(Color.FromRgb((byte)((r + m) * 255), (byte)((g + m) * 255), (byte)((b + m) * 255)));
    }
}
