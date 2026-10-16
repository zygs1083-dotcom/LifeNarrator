using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using LifeNarrator.Windows;

internal static class IconChecks
{
    public static void Run()
    {
        Directory.CreateDirectory("artifacts/rest/icons");
        using var normal = AppIcons.Tray(false, false);
        using var paused = AppIcons.Tray(true, false);
        using var error = AppIcons.Tray(false, true);
        using var pausedError = AppIcons.Tray(true, true);
        normal.Save("artifacts/rest/icons/ui-tray-normal.png");
        paused.Save("artifacts/rest/icons/ui-tray-paused.png");
        error.Save("artifacts/rest/icons/ui-tray-error.png");
        pausedError.Save("artifacts/rest/icons/ui-tray-paused-error.png");
        using var a = normal.Lock(); using var b = paused.Lock(); using var c = error.Lock(); using var d = pausedError.Lock();
        var row = new byte[128]; var gray = new byte[128]; var red = new byte[128]; var grayRed = new byte[128];
        var colored = 0; var dots = 0;
        for (var y = 0; y < 32; y++)
        {
            Marshal.Copy(a.Address + y * a.RowBytes, row, 0, 128); Marshal.Copy(b.Address + y * b.RowBytes, gray, 0, 128);
            Marshal.Copy(c.Address + y * c.RowBytes, red, 0, 128); Marshal.Copy(d.Address + y * d.RowBytes, grayRed, 0, 128);
            for (var x = 0; x < 32; x++)
            {
                var i = x * 4;
                if (row[i + 3] != gray[i + 3] || gray[i] != gray[i + 1] || gray[i] != gray[i + 2]) throw new Exception("Paused icon lost alpha or grayscale");
                if (row[i + 3] > 128 && row[i + 2] - row[i + 1] > 30) colored++;
                if (!row.AsSpan(i, 4).SequenceEqual(red.AsSpan(i, 4)))
                {
                    if (x < 22 || y < 22 || red[i + 2] <= red[i + 1] * 2 || !red.AsSpan(i, 4).SequenceEqual(grayRed.AsSpan(i, 4)))
                        throw new Exception("Error dot is not red/in the lower right/on the paused icon");
                    dots++;
                }
                else if (!gray.AsSpan(i, 4).SequenceEqual(grayRed.AsSpan(i, 4))) throw new Exception("Error variant changed the base icon");
            }
        }
        if (colored < 100 || dots < 20) throw new Exception("App icon or error indicator missing");
        var states = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 20, Margin = new Thickness(20) };
        foreach (var (name, bitmap) in new[] { ("Normal", normal), ("Paused", paused), ("Error", error), ("Paused + error", pausedError) })
            states.Children.Add(Views.Stack(new Image { Source = bitmap, Width = 96, Height = 96 }, Views.Label(name)));
        var window = new Window { Width = 540, Height = 175, Content = states };
        window.Show(); window.UpdateLayout();
        if (window.Icon != AppIcons.Window) throw new Exception("Global window icon missing");
        using var screenshot = new Avalonia.Media.Imaging.RenderTargetBitmap(new PixelSize(540, 175), new Vector(96, 96));
        screenshot.Render(window); screenshot.Save("artifacts/rest/icons/ui-app-icons.png"); window.Close();
        Console.WriteLine("PASS: app PNG, normal/paused/error/paused-error tray variants, alpha preservation and global window icon; artifacts/rest/icons");
    }
}
