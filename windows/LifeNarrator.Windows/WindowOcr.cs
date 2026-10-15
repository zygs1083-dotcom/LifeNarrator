using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace LifeNarrator.Windows;

internal sealed class WindowOcr
{
    internal record Word(TextSpan Span, Box Rect);
    internal record Line(TextLine TextLine, Word[] Words);
    readonly OcrEngine? engine;
    nint lastWindow;
    ulong? lastHash;
    Line[] cached = [];

    public WindowOcr(Action<bool> unavailable)
    {
        var languages = OcrEngine.AvailableRecognizerLanguages;
        var language = languages.FirstOrDefault(x => x.LanguageTag is "zh-Hans" or "zh-CN" or "zh-Hans-CN")
            ?? languages.FirstOrDefault(x => x.LanguageTag == "en-US");
        engine = language == null ? null : OcrEngine.TryCreateFromLanguage(language);
        unavailable(engine == null);
    }

    public Line[] Read(nint window, Box frame, DisplayMap display)
    {
        if (engine == null) return [];
        var image = Native.CaptureWindow(window);
        // Hash a reduced image; window coordinates are excluded so moving it reuses recognition.
        var hash = 14695981039346656037UL;
        for (var y = 0; y < 64; y++)
            for (var x = 0; x < 64; x++)
            {
                var offset = ((y * image.Height / 64) * image.Width + x * image.Width / 64) * 4;
                for (var c = 0; c < 3; c++) hash = unchecked((hash ^ image.Pixels[offset + c]) * 1099511628211UL);
            }
        hash = unchecked((hash ^ (ulong)image.Width) * 1099511628211UL ^ (ulong)image.Height);
        if (lastWindow != window || lastHash != hash)
        {
            var scale = Math.Min(1, OcrEngine.MaxImageDimension / (double)Math.Max(image.Width, image.Height));
            var width = (int)(image.Width * scale);
            var height = (int)(image.Height * scale);
            var pixels = image.Pixels;
            if (scale < 1)
            {
                pixels = new byte[width * height * 4];
                for (var y = 0; y < height; y++)
                    for (var x = 0; x < width; x++)
                        Array.Copy(image.Pixels, ((int)(y / scale) * image.Width + (int)(x / scale)) * 4,
                            pixels, (y * width + x) * 4, 4);
            }
            using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(pixels.AsBuffer(), BitmapPixelFormat.Bgra8,
                width, height, BitmapAlphaMode.Ignore);
            var result = engine.RecognizeAsync(bitmap).AsTask().GetAwaiter().GetResult();
            cached = result.Lines.Select(line =>
            {
                var offset = 0;
                var words = line.Words.Select(word =>
                {
                    var start = line.Text.IndexOf(word.Text, offset, StringComparison.Ordinal);
                    offset = start + word.Text.Length;
                    var r = word.BoundingRect;
                    return new Word(new TextSpan(start, word.Text.Length), new Box(r.X / scale, r.Y / scale, r.Width / scale, r.Height / scale));
                }).ToArray();
                var bounds = words.Select(w => w.Rect.Rect).Aggregate((a, b) => a.Union(b));
                return new Line(new TextLine(line.Text, Box.From(bounds), "text"), words);
            }).ToArray();
            lastWindow = window; lastHash = hash;
            if (Environment.GetEnvironmentVariable("LIFENARRATOR_DEBUG") == "1")
                Console.Error.WriteLine($"[ocr] recognized language={engine.RecognizerLanguage.LanguageTag} lines={cached.Length} hash={hash}");
        }
        return cached.Select(line => new Line(line.TextLine with { Rect = Screen(line.TextLine.Rect) },
            line.Words.Select(word => word with { Rect = Screen(word.Rect) }).ToArray())).ToArray();

        Box Screen(Box rect) => display.Logical(rect.Offset(frame.X, frame.Y));
    }

    internal static Box TextRect(Line line, TextSpan span) => Box.From(line.Words
        .Where(word => word.Span.Location < span.Location + span.Length && word.Span.Location + word.Span.Length > span.Location)
        .Select(word => word.Rect.Rect).Aggregate((a, b) => a.Union(b)));
}
