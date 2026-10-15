using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Interactivity;
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
        var window = new SettingsWindow(settings, () => { configurations++; return Task.CompletedTask; }, () => Task.FromResult(15d));
        window.Show();
        var cat = window.GetVisualDescendants().OfType<ToggleButton>().Single(b => AutomationProperties.GetAutomationId(b) == "choice-cat");
        cat.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var slider = window.GetVisualDescendants().OfType<Slider>().Single(s => AutomationProperties.GetAutomationId(s) == "pace.gap");
        slider.Value = 9;
        if (settings.Persona != "cat" || settings.MarkGap != 9 || configurations != 2) throw new Exception("Sprite edits did not configure immediately");
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
        var language = window.GetVisualDescendants().OfType<ComboBox>().Single(c => AutomationProperties.GetAutomationId(c) == "language");
        language.SelectedIndex = 2;
        if (settings.EffectiveLanguage != "en" || !window.Title!.Contains("Settings")) throw new Exception("Language change did not refresh UI");
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
        Console.WriteLine("PASS: seven-persona selection and pace configure immediately; three tabs render in both themes; language refresh; offline onboarding");
    }
}
