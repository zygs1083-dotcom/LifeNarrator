using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class OnboardingWindow : Window
{
    readonly Settings settings;
    readonly Texts text;
    readonly Func<Task> configure;
    readonly Func<Task<double>> testConnection;
    readonly Action completed;
    int step;
    TextBlock error = new() { IsVisible = false, TextWrapping = TextWrapping.Wrap };

    public OnboardingWindow(Settings settings, Func<Task> configure, Func<Task<double>> testConnection, Action completed)
    {
        this.settings = settings; this.configure = configure; this.testConnection = testConnection; this.completed = completed;
        text = new Texts(settings); Title = text["app.name"];
        Width = 660; Height = 600; MinWidth = 620; MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        AutomationProperties.SetAutomationId(this, "onboarding");
        Render();
    }

    void Render()
    {
        error = new TextBlock { IsVisible = false, TextWrapping = TextWrapping.Wrap };
        error.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        var title = Views.Label(text["onboarding.title"]); title.FontSize = 26; title.FontWeight = FontWeight.Bold;
        var progress = Views.Caption(text["onboarding.step"].Replace("%d", (step + 1).ToString()));
        var page = step switch
        {
            0 => Views.Card(text["onboarding.accessibility"], Views.Label(text["windows.reading"]), Views.Caption(text["windows.privacy"])),
            1 => Views.Card(text["onboarding.model"], Views.Choices([
                ("api", text["provider.api"], text["provider.api.hint"]),
                ("none", text["provider.none"], text["provider.none.hint"]),
                ("builtin", text["provider.builtin"], text["comingSoon"])], settings.Provider.Kind,
                id => { settings.Provider.Kind = id; }, disabled: "builtin")),
            2 => (Control)new ModelView(settings, configure, testConnection),
            _ => Views.Card(text["ready"], Views.Label(text["onboarding.done"]), Views.Caption(text["windows.privacy"]))
        };
        var back = Views.Button(text["back"], () => { step = step == 3 && settings.Provider.Kind == "none" ? 1 : step - 1; Render(); });
        back.IsVisible = step > 0;
        var next = Views.Button(text[step == 3 ? "finish" : "continue"], async () => await Advance());
        next.Classes.Add("primary"); AutomationProperties.SetAutomationId(next, "onboarding-next");
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (step == 2) actions.Children.Add(Views.Button(text["skip"], async () => { settings.Provider.Kind = "none"; await Advance(); }));
        actions.Children.Add(next);
        var footer = Views.Row(back, actions);
        var dock = new DockPanel { Margin = new Thickness(20) };
        var heading = Views.Stack(title, progress); heading.Margin = new Thickness(0, 0, 0, 20);
        DockPanel.SetDock(heading, Dock.Top); dock.Children.Add(heading);
        var bottom = Views.Stack(error, footer); bottom.Margin = new Thickness(0, 14, 0, 0);
        DockPanel.SetDock(bottom, Dock.Bottom); dock.Children.Add(bottom);
        dock.Children.Add(new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        Content = dock;
    }

    internal async Task Advance()
    {
        error.IsVisible = false;
        try
        {
            if (step == 3)
            {
                settings.OnboardingCompleted = true; await configure(); completed(); Close(); return;
            }
            if (step == 1 && settings.Provider.Kind == "api") settings.Save();
            else if (step > 0) await configure();
            step += step == 1 && settings.Provider.Kind == "none" ? 2 : 1;
            Render();
        }
        catch (Exception failure) { error.Text = failure.Message; error.IsVisible = true; }
    }
}
