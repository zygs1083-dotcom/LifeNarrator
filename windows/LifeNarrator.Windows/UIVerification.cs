using System.ComponentModel;
using System.Runtime.InteropServices;
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
                for (var index = 0; index < 6; index++)
                {
                    settingsWindow.SelectTab(index);
                    await Capture($"ui-settings-{index}-{language}-{theme}");
                }
            }
            settingsWindow.Close();
            var screen = verificationScreen;
            SetCursorPos(screen.X + screen.Width / 2, screen.Y + 100);
            foreach (var button in new[] { 0x202, 0x205 })
            {
                if (!PostMessage(tray.Handle, 0x800, 1, button)) throw new Win32Exception();
                await Task.Delay(300);
                if (trayMenu?.IsVisible != true || trayMenu.GetVisualDescendants().OfType<Button>().Count() < 4)
                    throw new Exception("Tray card did not open for button " + button);
                var outside = new Window { Width = 100, Height = 100 }; outside.Show(); outside.Activate();
                await Task.Delay(150);
                if (trayMenu.IsVisible) throw new Exception("Tray card did not dismiss on outside activation");
                outside.Close();
            }
            ShowTray(new Avalonia.PixelPoint(screen.X + screen.Width / 2, screen.Y + 100));
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

    async Task VerifyCompanion()
    {
        try
        {
            var watch = System.Diagnostics.Stopwatch.StartNew();
            while (!overlay!.HasShown && watch.Elapsed < TimeSpan.FromSeconds(60)) await Task.Delay(100);
            if (!overlay.HasShown) throw new Exception("No narration before companion verification");
            var probe = new Window(); verificationScreen = probe.Screens.Primary!.Bounds; probe.Close();
            await Capture("e2e-star-bubble");
            await brain!.Call("growth.setName", new { name = "小星" }); await companion.Refresh();
            await ShowChat("有我陪你呀");
            await chatWindow!.Send("请记住我喜欢抹茶");
            if (!companion.Memories.Any(m => m.Text == "喜欢抹茶")) throw new Exception("Chat remember intent did not reach memory store");
            await Capture("e2e-chat");
            await chatWindow.Send("安静点");
            if (settings.Liveliness != "quiet") throw new Exception("Chat setting intent did not configure host");
            await chatWindow.Send("讨厌开会");
            if (settings.Rules.Length != 1 || companion.Growth!.State.RulesLearned != 1) throw new Exception("Chat rule intent did not persist/record growth");
            chatWindow.Hide(); ShowSettings();
            settingsWindow!.SelectTab(SettingsWindow.MemoryTab); await Capture("e2e-memory");
            settingsWindow.SelectTab(0); await Capture("e2e-growth");
            Artifact.Write("e2e-companion.json", new { chat = true, memory = true, growth = true, starBubble = true,
                name = companion.Growth.Name, level = companion.Growth.State.Level, rules = settings.Rules.Length, setting = settings.Liveliness });
            exiting = true; await Stop(); tray.Dispose(); desktop.Shutdown();
        }
        catch (Exception failure)
        {
            Artifact.Write("e2e-companion-failure.json", new { error = failure.ToString() });
            exiting = true; await Stop(); tray.Dispose(); desktop.Shutdown(1);
        }
    }

    async Task Capture(string name)
    {
        await Task.Delay(600);
        Native.CaptureScreen(Artifact.PathFor(name + ".png"), verificationScreen);
    }
}
