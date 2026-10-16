using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Platform;

namespace LifeNarrator.Windows;

internal static class AppIcons
{
    public static Bitmap Image { get; } = LoadImage();
    public static WindowIcon Window { get; } = LoadWindow();

    static Bitmap LoadImage()
    {
        using var stream = typeof(AppIcons).Assembly.GetManifestResourceStream("LifeNarrator.AppIcon.png")!;
        return new Bitmap(stream);
    }
    static WindowIcon LoadWindow()
    {
        using var stream = typeof(AppIcons).Assembly.GetManifestResourceStream("LifeNarrator.AppIcon.ico")!;
        return new WindowIcon(stream);
    }

    public static WriteableBitmap Tray(bool paused, bool error)
    {
        var bitmap = new WriteableBitmap(new PixelSize(32, 32), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Unpremul);
        using var source = Image.CreateScaledBitmap(new PixelSize(32, 32), BitmapInterpolationMode.HighQuality);
        using var buffer = bitmap.Lock(); source.CopyPixels(buffer, AlphaFormat.Unpremul);
        var row = new byte[128];
        for (var y = 0; y < 32; y++)
        {
            Marshal.Copy(buffer.Address + y * buffer.RowBytes, row, 0, row.Length);
            for (var x = 0; x < 32; x++)
            {
                var index = x * 4;
                if (paused)
                {
                    var gray = (byte)Math.Round(.2126 * row[index + 2] + .7152 * row[index + 1] + .0722 * row[index]);
                    row[index] = row[index + 1] = row[index + 2] = gray;
                }
                if (error && (x - 26.5) * (x - 26.5) + (y - 26.5) * (y - 26.5) <= 16)
                { row[index] = 65; row[index + 1] = 55; row[index + 2] = 225; row[index + 3] = 255; }
            }
            Marshal.Copy(row, 0, buffer.Address + y * buffer.RowBytes, row.Length);
        }
        return bitmap;
    }
}
