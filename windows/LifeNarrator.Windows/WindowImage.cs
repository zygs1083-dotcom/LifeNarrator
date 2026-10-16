using System.Runtime.InteropServices;
using SkiaSharp;

namespace LifeNarrator.Windows;

internal static class WindowImage
{
    [DllImport("user32.dll")] static extern bool IsWindow(nint window);
    [DllImport("user32.dll")] static extern bool IsIconic(nint window);

    internal static byte[] Capture(nint window, Box frame, Box[] redactions, DisplayMap display)
    {
        CheckFrame();
        Native.WindowImage image;
        try { image = Native.CaptureWindow(window); }
        catch (System.ComponentModel.Win32Exception) { CheckFrame(); throw; }
        CheckFrame();
        using var bitmap = new SKBitmap(image.Width, image.Height, SKColorType.Bgra8888, SKAlphaType.Opaque);
        Marshal.Copy(image.Pixels, 0, bitmap.GetPixels(), image.Pixels.Length);
        using (var canvas = new SKCanvas(bitmap))
        using (var black = new SKPaint { Color = SKColors.Black })
        {
            foreach (var rect in redactions)
            {
                var sx = image.Width / frame.W; var sy = image.Height / frame.H;
                canvas.DrawRect(SKRect.Create((float)Math.Floor((rect.X - frame.X) * sx),
                    (float)Math.Floor((rect.Y - frame.Y) * sy),
                    (float)(Math.Ceiling((rect.X + rect.W - frame.X) * sx) - Math.Floor((rect.X - frame.X) * sx)),
                    (float)(Math.Ceiling((rect.Y + rect.H - frame.Y) * sy) - Math.Floor((rect.Y - frame.Y) * sy))), black);
            }
        }
        var scale = Math.Min(1, 1280d / Math.Max(image.Width, image.Height));
        using var resized = bitmap.Resize(new SKImageInfo(Math.Max(1, (int)(image.Width * scale)),
            Math.Max(1, (int)(image.Height * scale))), SKFilterQuality.Medium)
            ?? throw new InvalidOperationException("Cannot resize window image");
        using var jpeg = resized.Encode(SKEncodedImageFormat.Jpeg, 70)
            ?? throw new InvalidOperationException("Cannot encode window JPEG");
        return jpeg.ToArray();

        void CheckFrame()
        {
            if (!IsWindow(window) || IsIconic(window) || !Native.GetWindowRect(window, out var current)
                || display.Logical(current.Box) != frame) throw new WindowUnavailableException();
        }
    }
}
