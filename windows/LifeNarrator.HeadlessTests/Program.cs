using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using LifeNarrator.Windows;

AppBuilder.Configure<Application>().UseSkia()
    .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false }).SetupWithoutStarting();
var window = new Window { Width = 600, Height = 320, Background = Brushes.Transparent, Content = new BubbleSample() };
window.Show();
using var bitmap = window.CaptureRenderedFrame() ?? throw new Exception("No rendered frame");
Directory.CreateDirectory("artifacts");
bitmap.Save("artifacts/bubble-headless.png");
using var pixels = bitmap.Lock();
var pixel = new byte[4];
Marshal.Copy(pixels.Address + 60 * pixels.RowBytes + 75 * 4, pixel, 0, 4);
if (pixel[3] != 255 || Math.Abs(pixel[0] - pixel[2]) > 30 || pixel[1] >= 220)
    throw new Exception($"Bubble fill missing: {string.Join(',', pixel)}");
window.Close();
Console.WriteLine("PASS: bubble rendered at 600x320; pink fill verified; artifacts/bubble-headless.png");
