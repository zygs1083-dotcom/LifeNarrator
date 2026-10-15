using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;

namespace LifeNarrator.Windows;

internal static class OcrSpike
{
    public static async Task Run()
    {
        var languages = OcrEngine.AvailableRecognizerLanguages;
        if (languages.Count == 0)
        {
            Artifact.Write("ocr.json", new { status = "unavailable", languages = Array.Empty<string>(),
                reason = "Runner has no OCR language packs; no silent fallback" });
            throw new InvalidOperationException("No installed Windows OCR languages");
        }
        var language = languages.FirstOrDefault(x => x.LanguageTag.StartsWith("zh")) ?? languages[0];
        var engine = OcrEngine.TryCreateFromLanguage(language)
            ?? throw new InvalidOperationException($"Cannot create OCR engine for {language.LanguageTag}");
        var file = await StorageFile.GetFileFromPathAsync(Artifact.PathFor("overlay.png"));
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bitmap);
        Artifact.Write("ocr.json", new { status = "recognized", languages = languages.Select(x => x.LanguageTag),
            selectedLanguage = language.LanguageTag, result.Text, result.TextAngle,
            coordinateSpace = "overlay.png physical pixels", width = bitmap.PixelWidth, height = bitmap.PixelHeight,
            lines = result.Lines.Select(line => new { line.Text, words = line.Words.Select(word => new {
                word.Text, rect = new { x = word.BoundingRect.X, y = word.BoundingRect.Y,
                    width = word.BoundingRect.Width, height = word.BoundingRect.Height } }) }) });
    }
}
