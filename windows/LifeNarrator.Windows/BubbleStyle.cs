using System.Text;
using Avalonia.Media;

namespace LifeNarrator.Windows;

[Flags]
public enum TextEffects { None = 0, Outline = 1, Shadow = 2, Gradient = 4 }

public sealed record BubbleStyle
{
    public static readonly string[] Shapes = ["text", "rounded", "cloud", "speech", "sticker", "note", "star"];
    public static readonly string[] Sizes = ["small", "medium", "large"];
    public static readonly string[] Themes = ["macaron", "candy", "neon", "random", "clear", "starry"];
    public static readonly string[] Fonts = ["persona", "hannotate", "yuanti", "wawati", "hanzipen", "noteworthy", "chalkboard", "markerFelt"];
    public static readonly string[] Animations = ["fade", "bounce", "slide", "pop"];
    public static readonly string[] Densities = ["none", "moderate", "many"];
    public static readonly string[] ExtraEmoji = ["🌟", "🥳", "🦊", "🐱", "🦄", "🍀", "🌈", "🚀"];
    public string Shape { get; init; } = "text";
    public string Size { get; init; } = "small";
    public string Theme { get; init; } = "clear";
    public string Font { get; init; } = "persona";
    public TextEffects TextEffects { get; init; } = TextEffects.Outline | TextEffects.Shadow;
    public string Animation { get; init; } = "fade";
    public string EmojiDensity { get; init; } = "moderate";
    public string? Emoji { get; init; }
    public double? Dwell { get; init; } = 3;
    public int MaxOnScreen { get; init; } = 3;

    internal double? EffectiveDwell => Dwell is { } seconds ? MaxOnScreen > 3 ? Math.Max(seconds, 2.5 * MaxOnScreen) : seconds : null;

    public string[] DisplayedEmoji(string[] original)
    {
        var selected = Emoji is { } fixedEmoji ? [fixedEmoji] : original;
        return EmojiDensity switch { "none" => [], "moderate" => selected.Take(1).ToArray(), _ => selected };
    }

    public static int? UnlockLevel(string option) => option switch
    {
        "star" => 5, "starry" => 15, _ when ExtraEmoji.Contains(option) => 3, _ => null
    };

    internal static ulong StableHash(string value)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(value)) hash = unchecked((hash ^ b) * 0x100000001b3UL);
        return hash;
    }
}

internal sealed record BubbleMetrics(string Size)
{
    double Pick(double small, double medium, double large) => Size switch { "small" => small, "medium" => medium, _ => large };
    public static double BlurRadius(double sigma) => (sigma - .5) * Math.Sqrt(12);
    public double FontSize => Pick(14, 18, 24);
    public double LineSpacing => Pick(2, 3, 4);
    public double MaxWidth => Pick(220, 300, 400);
    public double HorizontalPadding => Pick(10, 14, 18);
    public double VerticalPadding => Pick(6, 9, 12);
    public double EmojiSize => Pick(16, 20, 26);
    public double StrokeWidth => Pick(1.5, 2, 2.5);
    public double RoundedRadius => Pick(16, 20, 26);
    public double SpeechRadius => Pick(12, 14, 18);
    public double TailBase => Pick(14, 18, 22);
    public double TailHeight => Pick(12, 16, 20);
    public double StickerRadius => Pick(8, 10, 12);
    public double PaperInset => Pick(4, 5, 6);
    public double TapeWidth => Pick(30, 36, 44);
    public double TapeHeight => Pick(10, 12, 14);
}

internal readonly record struct BubbleColors(Color Fill, Color Text, Color Stroke)
{
    static BubbleColors Hex(uint fill, uint text, uint stroke) => new(Rgb(fill), Rgb(text), Rgb(stroke));
    static Color Rgb(uint value) => Color.FromUInt32(0xff000000 | value);
    public static readonly double[] ClearHues = [350, 18, 42, 68, 100, 150, 175, 200, 222, 255, 285, 320];
    public static BubbleColors[] Palette(string theme) => theme switch
    {
        "macaron" => [Hex(0xBFF0DD, 0x1F5A46, 0x7ED3B2), Hex(0xFFD6C9, 0x7A3A2A, 0xF5A98F), Hex(0xE2D9F7, 0x45307A, 0xB9A6E8), Hex(0xFFF3B8, 0x6B5400, 0xF2D96B), Hex(0xCFE8FF, 0x1F4B7A, 0x8EC6F7), Hex(0xFFD9E8, 0x7A2B4B, 0xF7A6C8)],
        "candy" => [Hex(0xFF6B9D, 0x3A0F24, 0xC2185B), Hex(0xFFB703, 0x4A2C00, 0xE08A00), Hex(0x4CC9F0, 0x04303E, 0x0096C7), Hex(0x80ED99, 0x0B3D1A, 0x2DC653), Hex(0xC77DFF, 0x2B0A4D, 0x9D4EDD), Hex(0xFFE066, 0x4A3A00, 0xF4B400)],
        "neon" => new uint[] { 0x39FF14, 0xFF2BD6, 0x00F0FF, 0xFFE600, 0xFF7A00, 0xB388FF }.Select(c => Hex(0x141430, c, c)).ToArray(),
        "starry" => [Hex(0x191D45, 0xFFF0B5, 0xB9ABFF), Hex(0x24204D, 0xE8DCFF, 0xC5ADFF), Hex(0x152E48, 0xD3F3FF, 0x8DD8F5), Hex(0x302049, 0xFFE1F2, 0xEDA8D2), Hex(0x182F37, 0xD2F8E9, 0x8CDAC2), Hex(0x302A43, 0xFFF2CE, 0xE9CC8F)],
        "clear" => ClearHues.Select(h => new BubbleColors(Hsv(h, .22, 1), Hsv(h, .78, .40), Hsv(h, .62, .96))).ToArray(),
        _ => throw new ArgumentOutOfRangeException(nameof(theme))
    };
    public static BubbleColors Random(double baseHue, int index)
    {
        var h = (baseHue + index * 137.5) % 360;
        return new(Hsv(h, .35, 1), Hsv(h, .80, .38), Hsv(h, .55, .85));
    }
    static Color Hsv(double hue, double saturation, double brightness)
    {
        var h = hue / 60;
        var c = brightness * saturation;
        var x = c * (1 - Math.Abs(h % 2 - 1));
        var (r, g, b) = h switch
        {
            < 1 => (c, x, 0d), < 2 => (x, c, 0d), < 3 => (0d, c, x),
            < 4 => (0d, x, c), < 5 => (x, 0d, c), _ => (c, 0d, x)
        };
        var m = brightness - c;
        return Color.FromRgb((byte)Math.Round((r + m) * 255), (byte)Math.Round((g + m) * 255), (byte)Math.Round((b + m) * 255));
    }
    public static Color WhiteMix(Color c, double amount) => Color.FromRgb(
        (byte)Math.Round(c.R + (255 - c.R) * amount), (byte)Math.Round(c.G + (255 - c.G) * amount), (byte)Math.Round(c.B + (255 - c.B) * amount));
}

internal static class BubbleFonts
{
    public static string WindowsFamily(string mac) => mac switch
    {
        "hannotate" or "Hannotate SC" or "hanzipen" or "Hanzipen SC" or "Kaiti SC" => "KaiTi, 楷体",
        "yuanti" or "Yuanti SC" => "DengXian, 等线",
        "wawati" or "Wawati SC" => "Microsoft YaHei UI",
        "noteworthy" or "Noteworthy" => "Segoe Print",
        "chalkboard" or "Chalkboard" or "Chalkboard SE" => "Comic Sans MS",
        "markerFelt" or "Marker Felt" => "Ink Free",
        "Chalkduster" => "Comic Sans MS",
        "Bradley Hand" => "Segoe Script",
        "PingFang SC" => "Microsoft YaHei UI",
        _ => mac
    };
    public static Typeface Typeface(string choice, string persona, string language)
    {
        var fonts = choice == "persona"
            ? Catalog.Personas.Single(p => p.Id == persona).Fonts[language == "zh" ? "zh" : "en"]
            : new[] { choice };
        var family = string.Join(", ", fonts.Select(WindowsFamily).Append("Microsoft YaHei UI"));
        return new Typeface(new FontFamily(family), FontStyle.Normal,
            fonts[0] is "wawati" or "Wawati SC" or "Chalkduster" ? FontWeight.Bold : FontWeight.Normal);
    }
}
