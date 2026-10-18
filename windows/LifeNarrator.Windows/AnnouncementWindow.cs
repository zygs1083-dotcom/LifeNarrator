using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed record UpdateAnnouncement(Localized Title, Localized Intro, Localized[] Items, Localized Dismiss)
{
    public static UpdateAnnouncement Load() => Catalog.Read<UpdateAnnouncement>("announcement.json");
    public static bool ShouldShow(Settings settings) => settings.OnboardingCompleted && settings.SeenAnnouncementVersion != AppRelease.CurrentVersion;
}

internal sealed class AnnouncementPresenter(Settings settings, Action save, Action<string> report)
{
    internal AnnouncementWindow? Window { get; private set; }
    public void ShowIfNeeded() { if (UpdateAnnouncement.ShouldShow(settings)) Show(); }
    public void Show()
    {
        if (!settings.OnboardingCompleted) return;
        try
        {
            if (Window == null)
            {
                var window = new AnnouncementWindow(settings, UpdateAnnouncement.Load());
                window.Closed += (_, _) =>
                {
                    Window = null;
                    try
                    {
                        var previous = settings.SeenAnnouncementVersion;
                        settings.SeenAnnouncementVersion = AppRelease.CurrentVersion;
                        try { save(); } catch { settings.SeenAnnouncementVersion = previous; throw; }
                    }
                    catch (Exception failure) { report(failure.Message); }
                };
                Window = window;
            }
            Window.Refresh(settings); Window.Show(); Window.Activate();
        }
        catch (Exception failure) { report(failure.Message); }
    }
}

internal sealed class AnnouncementWindow : Window
{
    readonly UpdateAnnouncement announcement;
    string? language;
    public AnnouncementWindow(Settings settings, UpdateAnnouncement announcement)
    {
        this.announcement = announcement;
        Width = 520; Height = 460; MinWidth = 320; MinHeight = 260;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        AutomationProperties.SetAutomationId(this, "announcement");
        Refresh(settings);
    }

    internal void Refresh(Settings settings)
    {
        var lang = settings.EffectiveLanguage;
        if (language == lang) return;
        language = lang;
        Title = announcement.Title.Text(lang);
        FontFamily = Views.Font(settings);
        var title = Views.Label(Title); title.FontSize = 20; title.FontWeight = FontWeight.SemiBold;
        var body = Views.Stack(Views.Caption(announcement.Intro.Text(lang)));
        foreach (var item in announcement.Items) body.Children.Add(Views.Label("•  " + item.Text(lang)));
        var scroll = new ScrollViewer { Name = "announcement-scroll", Content = Views.Card(Title, "\uE734", 42, null, body),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var dismiss = Views.Primary(announcement.Dismiss.Text(lang), Close); dismiss.IsDefault = true;
        dismiss.HorizontalAlignment = HorizontalAlignment.Right;
        AutomationProperties.SetAutomationId(dismiss, "announcement-dismiss");
        var layout = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), RowSpacing = 16, Margin = new Thickness(20) };
        layout.Children.Add(Views.Row(title, Views.Badge("v" + AppRelease.CurrentVersion, 42)));
        Grid.SetRow(scroll, 1); layout.Children.Add(scroll); Grid.SetRow(dismiss, 2); layout.Children.Add(dismiss);
        Content = layout;
    }
}
