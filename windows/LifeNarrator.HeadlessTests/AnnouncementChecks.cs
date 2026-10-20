using System.Text.Json;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class AnnouncementChecks
{
    static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    public static void Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), "announcement-" + Guid.NewGuid());
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "settings.json");
            var settings = JsonSerializer.Deserialize<Settings>("{\"onboardingCompleted\":false}", Protocol.Json)!;
            Require(settings.SeenAnnouncementVersion == null, "Legacy settings must default to unseen");
            var errors = new List<string>(); var saves = 0;
            var presenter = new AnnouncementPresenter(settings, () =>
            { File.WriteAllText(path, JsonSerializer.Serialize(settings, Protocol.Json)); saves++; }, errors.Add);
            presenter.ShowIfNeeded(); presenter.Show();
            Require(presenter.Window == null && saves == 0, "Onboarding must keep focus");
            settings.OnboardingCompleted = true; presenter.ShowIfNeeded();
            var first = presenter.Window!;
            Require(first.IsVisible && saves == 0 && settings.SeenAnnouncementVersion == null, "First launch must show without marking read");
            presenter.Show(); Require(ReferenceEquals(first, presenter.Window), "Repeated click must reuse window");
            settings.Language = "en"; presenter.Show();
            Require(first.Title == "What is new", "Open notes must use current application language");
            first.Close();
            var reloaded = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Protocol.Json)!;
            Require(saves == 1 && reloaded.SeenAnnouncementVersion == AppRelease.CurrentVersion && errors.Count == 0, "Close must persist current version");
            var restarted = new AnnouncementPresenter(reloaded, () => { }, errors.Add);
            restarted.ShowIfNeeded(); Require(restarted.Window == null, "Restart must not repeat seen notes");
            using var updater = new Updater();
            var preferences = new SettingsWindow(reloaded, () => Task.CompletedTask, () => Task.FromResult(1d), updater,
                () => Task.CompletedTask, showAnnouncement: restarted.Show);
            preferences.Show(); preferences.SelectTab(SettingsWindow.GeneralTab); Dispatcher.UIThread.RunJobs();
            var manual = preferences.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "updates-announcement");
            manual.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); var opened = restarted.Window;
            manual.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Require(opened != null && ReferenceEquals(opened, restarted.Window), "Settings entry must open and focus a single window");
            restarted.Window!.Close(); preferences.Close();
            reloaded.SeenAnnouncementVersion = "0.9.9";
            Require(UpdateAnnouncement.ShouldShow(reloaded), "A new version must be announced");
            var failed = new AnnouncementPresenter(reloaded, () => throw new IOException("fixture write failure"), errors.Add);
            failed.ShowIfNeeded(); failed.Window!.Close();
            Require(errors.SequenceEqual(new[] { "fixture write failure" }) && reloaded.SeenAnnouncementVersion == "0.9.9", "Persistence failures must be reported and remain unread");
            Directory.CreateDirectory("artifacts/announcements");
            foreach (var language in new[] { "zh", "en" })
            foreach (var theme in new[] { ThemeVariant.Light, ThemeVariant.Dark })
            foreach (var small in new[] { false, true })
            {
                Application.Current!.RequestedThemeVariant = theme;
                settings.Language = language;
                var notes = UpdateAnnouncement.Load();
                Require(notes.Items.Length > 0 && notes.Items.All(i => i.Text(language).Length > 10), "Complete localized announcement required");
                var window = new AnnouncementWindow(settings, notes);
                if (small) { window.Width = 320; window.Height = 260; }
                window.Show(); Dispatcher.UIThread.RunJobs(); window.UpdateLayout();
                var scroll = window.GetVisualDescendants().OfType<ScrollViewer>().Single(s => s.Name == "announcement-scroll");
                Require(scroll.Extent.Width <= scroll.Viewport.Width + 1, "Announcement must fit horizontally");
                if (small) Require(scroll.Extent.Height > scroll.Viewport.Height, "Small window must scroll");
                using (var frame = window.CaptureRenderedFrame() ?? throw new Exception("No announcement pixels"))
                    frame.Save($"artifacts/announcements/{language}-{theme}-{(small ? "small" : "normal")}.png");
                scroll.ScrollToEnd(); Dispatcher.UIThread.RunJobs();
                if (small)
                {
                    using var end = window.CaptureRenderedFrame() ?? throw new Exception("No scrolled announcement pixels");
                    end.Save($"artifacts/announcements/{language}-{theme}-small-end.png");
                }
                var dismiss = window.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "announcement-dismiss");
                Require(dismiss.IsVisible && dismiss.Bounds.Height > 0, "Dismiss must remain available");
                dismiss.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Require(!window.IsVisible, "Got it must close notes");
            }
            Console.WriteLine("PASS: announcement onboarding/first launch, close and persist, restart, manual single window, old settings, save failure, bilingual light/dark and small-screen screenshots");
        }
        finally { Directory.Delete(directory, true); }
    }
}
