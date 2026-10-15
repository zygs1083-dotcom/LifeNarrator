using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        Directory.CreateDirectory(Artifact.DirectoryPath);
        switch (args.Single())
        {
            case "spike-overlay":
                return AppBuilder.Configure<OverlayApp>().UsePlatformDetect()
                    .With(new Win32PlatformOptions { RenderingMode = [Win32RenderingMode.Software],
                        CompositionMode = [Win32CompositionMode.RedirectionSurface] })
                    .StartWithClassicDesktopLifetime(args);
            case "spike-uia":
                AppBuilder.Configure<Application>().UsePlatformDetect().SetupWithoutStarting();
                UiaSpike.Run(); break;
            case "spike-brain": BrainSpike.Run().GetAwaiter().GetResult(); break;
            case "spike-ocr": OcrSpike.Run().GetAwaiter().GetResult(); break;
            default: throw new ArgumentException("Expected spike-overlay, spike-uia, spike-brain or spike-ocr");
        }
        return 0;
    }
}

public sealed class OverlayApp : Application
{
    public override void OnFrameworkInitializationCompleted()
    {
        var desktop = (IClassicDesktopStyleApplicationLifetime)ApplicationLifetime!;
        var window = new Window
        {
            SystemDecorations = SystemDecorations.None, ShowInTaskbar = false, ShowActivated = false,
            Topmost = true, CanResize = false, Background = Brushes.Transparent,
            TransparencyLevelHint = [WindowTransparencyLevel.Transparent], Content = new BubbleSample()
        };
        // Avalonia recomputes extended styles when showing or changing window properties.
        Win32Properties.AddWindowStylesCallback(window, (style, extended) => (style, extended | Native.OverlayExtendedStyles));
        var screen = window.Screens.Primary!;
        window.Position = screen.Bounds.Position;
        window.Width = screen.Bounds.Width / screen.Scaling;
        window.Height = screen.Bounds.Height / screen.Scaling;
        var handle = window.TryGetPlatformHandle()!.Handle;
        Native.ApplyOverlayStyles(handle);
        var foreground = Native.GetForegroundWindow();
        window.Opened += async (_, _) =>
        {
            Native.EnableLayeredWindow(handle);
            await Task.Delay(1500);
            var styles = Native.OverlayStyles(handle);
            Native.CaptureScreen(Artifact.PathFor("overlay.png"), screen.Bounds);
            Artifact.Write("overlay.json", new { styles, foregroundBefore = foreground.ToInt64(),
                foregroundAfter = Native.GetForegroundWindow().ToInt64(),
                focusPreserved = foreground == Native.GetForegroundWindow(),
                transparency = window.ActualTransparencyLevel.ToString(), scaling = screen.Scaling,
                screen = screen.Bounds.ToString(), renderer = "Software / RedirectionSurface" });
            if (styles.Any(x => !x.Value) || foreground != Native.GetForegroundWindow())
                throw new InvalidOperationException("Overlay styles or no-activation check failed");
            desktop.Shutdown();
        };
        desktop.MainWindow = window;
        base.OnFrameworkInitializationCompleted();
    }
}
