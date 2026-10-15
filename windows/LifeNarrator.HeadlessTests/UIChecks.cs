using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.Input;
using Avalonia.Styling;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class UIChecks
{
    public static void Run()
    {
        Application.Current!.Styles.Add(new AppTheme());
        var settings = new Settings { Language = "zh" };
        var configurations = 0;
        using var updater = new Updater();
        var window = new SettingsWindow(settings, () => { configurations++; return Task.CompletedTask; }, () => Task.FromResult(15d), updater, () => Task.CompletedTask);
        window.Show();
        var cat = window.GetVisualDescendants().OfType<ToggleButton>().Single(b => AutomationProperties.GetAutomationId(b) == "choice-cat");
        cat.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var slider = window.GetVisualDescendants().OfType<Slider>().Single(s => AutomationProperties.GetAutomationId(s) == "pace.gap");
        slider.Value = 9;
        slider.Focus(); window.KeyPressQwerty(PhysicalKey.ArrowRight, RawInputModifiers.None); window.KeyReleaseQwerty(PhysicalKey.ArrowRight, RawInputModifiers.None);
        if (settings.MarkGap != 10) throw new Exception("Pace slider does not support keyboard input");
        if (settings.Persona != "cat" || settings.MarkGap != 10 || configurations != 3) throw new Exception("Sprite edits did not configure immediately");
        foreach (var variant in new[] { ThemeVariant.Light, ThemeVariant.Dark })
        {
            Application.Current.RequestedThemeVariant = variant;
            for (var tab = 0; tab < 3; tab++)
            {
                window.SelectTab(tab);
                using var frame = window.CaptureRenderedFrame() ?? throw new Exception("No settings pixels");
                frame.Save($"artifacts/ui-headless-{variant}-{tab}.png");
            }
        }
        window.SelectTab(2); window.UpdateLayout();
        var blacklist = window.GetVisualDescendants().OfType<TextBox>().Single(c => AutomationProperties.GetAutomationId(c) == "blacklist");
        blacklist.Focus(); window.KeyTextInput("notepad");
        if (!settings.Blacklist.SequenceEqual(new[] { "notepad" })) throw new Exception("Blacklist text input did not configure");
        var language = window.GetVisualDescendants().OfType<ComboBox>().Single(c => AutomationProperties.GetAutomationId(c) == "language");
        language.SelectedIndex = 2;
        if (settings.EffectiveLanguage != "en" || !window.Title!.Contains("Settings")) throw new Exception("Language change did not refresh UI");
        window.UpdateLayout();
        var automatic = window.GetVisualDescendants().OfType<ToggleButton>().Single(b => AutomationProperties.GetName(b) == "Automatically check for updates");
        automatic.IsChecked = false;
        automatic.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (settings.AutomaticUpdates) throw new Exception("Automatic update toggle did not change settings");
        if (window.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "updates-check").Content?.ToString() != "Check for updates")
            throw new Exception("Update check button was not localized");
        window.Close();
        var complete = false;
        var wizard = new OnboardingWindow(new Settings(), () => Task.CompletedTask, () => Task.FromResult(1d), () => complete = true);
        wizard.Show();
        for (var i = 0; i < 3; i++)
        {
            wizard.UpdateLayout();
            wizard.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "onboarding-next")
                .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        }
        if (!complete || wizard.IsVisible) throw new Exception("Offline onboarding did not finish");
        var pending = new TaskCompletionSource();
        var busyWizard = new OnboardingWindow(new Settings(), () => pending.Task, () => Task.FromResult(1d), () => { });
        busyWizard.Show();
        Button Next()
        {
            busyWizard.UpdateLayout();
            return busyWizard.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "onboarding-next");
        }
        Next().RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var waiting = Next(); waiting.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (waiting.IsEffectivelyEnabled) throw new Exception("Onboarding permits repeated navigation while configuring");
        pending.SetResult();
        Avalonia.Threading.Dispatcher.UIThread.RunJobs();
        busyWizard.Close();
        Console.WriteLine("PASS: seven-persona selection and pace configure immediately; three tabs render in both themes; language refresh; offline onboarding");
    }
}
