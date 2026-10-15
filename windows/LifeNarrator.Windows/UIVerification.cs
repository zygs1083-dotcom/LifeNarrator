using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Interactivity;
using Avalonia.Styling;
using Avalonia.VisualTree;

namespace LifeNarrator.Windows;

public sealed partial class ShellApp
{
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate bool EnumWindowCallback(nint window, nint param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowCallback callback, nint param);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(nint window, out uint processID);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(nint window, StringBuilder text, int length);
    [DllImport("user32.dll", SetLastError = true)] static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);

    PixelRect verificationScreen;

    async Task VerifyUI()
    {
        Directory.CreateDirectory(Artifact.DirectoryPath);
        try
        {
            if (onboarding == null) throw new Exception("First launch must show onboarding");
            verificationScreen = onboarding.Screens.Primary!.Bounds;
            await Capture("ui-onboarding");
            var welcome = onboarding;
            for (var index = 0; index < 3; index++) await welcome.Advance();
            await Task.Delay(300);
            if (!settings.OnboardingCompleted || settingsWindow == null) throw new Exception("Offline onboarding did not finish");
            await Stop();
            settings.Provider = new ProviderSettings { Kind = "api" };
            try { await Start(); throw new Exception("Incomplete API draft unexpectedly configured"); }
            catch (BrainException) { }
            settings.Provider.Kind = "none";
            await Configure();
            if (eventPump == null || eventPump.IsCompleted) throw new Exception("Correcting an API draft did not restore the event pump");
            settingsWindow.SelectTab(0); settingsWindow.UpdateLayout();
            var cat = settingsWindow.GetVisualDescendants().OfType<ToggleButton>().Single(b => AutomationProperties.GetAutomationId(b) == "choice-cat");
            cat.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var slider = settingsWindow.GetVisualDescendants().OfType<Slider>().Single(s => AutomationProperties.GetAutomationId(s) == "pace.gap");
            slider.Value = 7;
            await Task.Delay(250);
            if (settings.Persona != "cat" || Settings.Load().MarkGap != 7) throw new Exception("Settings edits not persisted");
            if ((await brain!.Call("ping", new { })).GetProperty("version").GetString() == null) throw new Exception("Brain not alive");
            settings.Provider = new ProviderSettings { Kind = "api", PresetId = "custom-openai", Model = "ci-stub", BaseURL = "http://127.0.0.1:18765/v1" };
            CredentialStore.Write(settings.Provider.PresetId, "ci-fixture-key");
            await Configure();
            var elapsed = await TestConnection();
            if (elapsed < 0) throw new Exception("Invalid connection timing");
            foreach (var (language, theme) in new[] { ("zh", ThemeVariant.Light), ("en", ThemeVariant.Dark) })
            {
                settings.Language = language; RequestedThemeVariant = theme; await Configure();
                for (var index = 0; index < 3; index++)
                {
                    settingsWindow.SelectTab(index);
                    await Capture($"ui-settings-{index}-{language}-{theme}");
                }
            }
            settingsWindow.Close();
            nint messageWindow = 0;
            EnumWindows((window, _) =>
            {
                GetWindowThreadProcessId(window, out var processID);
                var name = new StringBuilder(256); GetClassName(window, name, name.Capacity);
                if (processID == Environment.ProcessId && name.ToString().StartsWith("AvaloniaMessageWindow ")) messageWindow = window;
                return true;
            }, 0);
            if (messageWindow == 0) throw new Exception("Tray message window not found");
            var screen = verificationScreen;
            SetCursorPos(screen.X + screen.Width / 2, screen.Y + 100);
            if (!PostMessage(messageWindow, 0x800, 1, 0x205)) throw new Win32Exception();
            await Task.Delay(300);
            var menu = desktop.Windows.Single(w => w.Name?.StartsWith("AvaloniaTrayPopupRoot_") == true);
            if (menu.GetVisualDescendants().OfType<MenuItem>().Count() < 5) throw new Exception("Tray menu did not render");
            await Capture("ui-tray-menu");
            Artifact.Write("ui-verification.json", new { installedExecutable = Environment.ProcessPath, onboarding = true, invalidDraftRecovery = true,
                persistedPersona = settings.Persona, markGap = settings.MarkGap, connectionMilliseconds = elapsed,
                themes = new[] { "Light", "Dark" }, languages = new[] { "zh", "en" } });
            exiting = true; await Stop(); tray.Dispose(); desktop.Shutdown();
        }
        catch (Exception failure)
        {
            Artifact.Write("ui-failure.json", new { error = failure.ToString() });
            exiting = true; await Stop(); tray.Dispose(); desktop.Shutdown(1);
        }
    }

    async Task Capture(string name)
    {
        await Task.Delay(600);
        Native.CaptureScreen(Artifact.PathFor(name + ".png"), verificationScreen);
    }
}
