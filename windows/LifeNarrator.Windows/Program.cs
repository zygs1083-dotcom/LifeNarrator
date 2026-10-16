using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal static class Program
{
    internal static bool VerifyUI, VerifyCompanion;
    internal static bool VerifyUpdate, VerifyUpdateResult;
    internal const string ShowSettingsEvent = "Local\\LifeNarrator.Windows.ShowSettings";
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.SequenceEqual(new[] { "--delete-user-data" }))
        {
            foreach (var provider in Catalog.Providers) CredentialStore.Delete(provider.Id);
            if (Directory.Exists(Settings.DataDirectory)) Directory.Delete(Settings.DataDirectory, recursive: true);
            return 0;
        }
        VerifyUI = args.SequenceEqual(new[] { "--verify-ui" });
        VerifyCompanion = args.SequenceEqual(new[] { "--verify-companion" });
        VerifyUpdate = args.SequenceEqual(new[] { "--verify-update" });
        VerifyUpdateResult = args.Length == 0 && Environment.GetEnvironmentVariable("LIFENARRATOR_VERIFY_UPDATE_RESULT") == "1";
        if (VerifyUpdate || VerifyUpdateResult) Directory.SetCurrentDirectory(Environment.GetEnvironmentVariable("LIFENARRATOR_UPDATE_WORKSPACE")!);
        if (args.Length == 0 || VerifyUI || VerifyCompanion || VerifyUpdate)
        {
            using var single = new Mutex(true, "Local\\LifeNarrator.Windows", out var first);
            if (!first)
            {
                // The tray icon often sits in the hidden overflow, so opening the app again shows the running copy's settings.
                using var show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowSettingsEvent);
                show.Set();
                return 0;
            }
            try { return Builder<ShellApp>().StartWithClassicDesktopLifetime(args); }
            finally { single.ReleaseMutex(); }
        }
        if (args.Length != 2 || args[0] != "--spike") throw new ArgumentException("Expected --spike overlay|uia|brain|ocr");
        Directory.CreateDirectory(Artifact.DirectoryPath);
        switch (args[1])
        {
            case "overlay":
                return Builder<OverlayApp>().StartWithClassicDesktopLifetime(args);
            case "uia":
                AppBuilder.Configure<Application>().UsePlatformDetect().SetupWithoutStarting();
                UiaSpike.Run(); break;
            case "follow-probe":
                var probe = new Thread(FollowProbe.Run);
                probe.SetApartmentState(ApartmentState.MTA);
                probe.Start(); probe.Join(); break;
            case "brain": BrainSpike.Run().GetAwaiter().GetResult(); break;
            case "ocr": OcrSpike.Run().GetAwaiter().GetResult(); break;
            default: throw new ArgumentException("Expected --spike overlay|uia|brain|ocr");
        }
        return 0;
    }

    static AppBuilder Builder<T>() where T : Application, new() => AppBuilder.Configure<T>().UsePlatformDetect()
        .With(new Win32PlatformOptions { RenderingMode = [Win32RenderingMode.Software],
            CompositionMode = [Win32CompositionMode.RedirectionSurface] });
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
