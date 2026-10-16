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
    readonly Func<Task<string[]>> ocrLanguages;
    int step;
    TextBlock error = null!;

    public OnboardingWindow(Settings settings, Func<Task> configure, Func<Task<double>> testConnection, Action completed,
        Func<Task<string[]>>? ocrLanguages = null)
    {
        this.settings = settings; this.configure = configure; this.testConnection = testConnection; this.completed = completed;
        this.ocrLanguages = ocrLanguages ?? (() => Task.FromResult(Array.Empty<string>()));
        text = new Texts(settings); Title = text["app.name"];
        Width = 620; Height = 500; MinWidth = 620; MinHeight = 500;
        FontFamily = Views.Font(settings);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        AutomationProperties.SetAutomationId(this, "onboarding");
        Render();
    }

    void Render()
    {
        error = Views.Caption(""); error.IsVisible = false;
        error.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        var title = Views.Label(text["onboarding.title"]); title.FontSize = 26; title.FontWeight = FontWeight.Bold;
        var dots = Views.Horizontal(); dots.Spacing = 8;
        for (var index = 0; index < 3; index++)
        {
            var dot = new Border { Width = step == index ? 20 : 6, Height = 6, CornerRadius = new CornerRadius(3) };
            dot.Bind(Border.BackgroundProperty, this.GetResourceObservable(step == index ? "Accent" : "Stroke")); dots.Children.Add(dot);
        }
        AutomationProperties.SetName(dots, text["onboarding.step"].Replace("%d", (step + 1).ToString()));
        var icon = new Image { Source = AppIcons.Image, Width = 56, Height = 56 };
        var header = Views.Horizontal(icon, Views.Stack(title, dots)); header.Spacing = 16;
        var pageTitle = Views.Label(text[step == 0 ? "onboarding.model" : step == 1 ? "onboarding.accessibility" : "windows.screenTitle"]);
        pageTitle.FontSize = 20; pageTitle.FontWeight = FontWeight.Bold;
        Control page;
        if (step == 0) page = new ModelView(settings, configure, testConnection, onboarding: true);
        else if (step == 1) page = Views.Stack(Views.Label(text["windows.reading"]), Views.Caption(text["windows.privacy"]), Views.Badge(text["windows.readingReady"], 150));
        else
        {
            var status = Views.Caption(text["ocr.checking"]);
            status.AttachedToVisualTree += async (_, _) =>
            {
                try
                {
                    var languages = await ocrLanguages();
                    status.Text = languages.Length == 0 ? text["ocr.unavailable"] : text["ocr.ready"].Replace("%@", string.Join(", ", languages));
                }
                catch (Exception failure) { error.Text = failure.Message; error.IsVisible = true; }
            };
            page = Views.Stack(Views.Label(text["windows.screenReading"]), Views.Card(text["ocr.title"], "\uE8D2", 42, null, status), Views.Caption(text["windows.privacy"]));
        }
        var back = Views.Button(text["back"], () => { step--; Render(); }); back.IsVisible = step > 0;
        var next = Views.Primary(text[step == 2 ? "finish" : "continue"], () => { }); next.IsDefault = true;
        AutomationProperties.SetAutomationId(next, "onboarding-next");
        var footer = Views.Row(back, next);
        next.Click += async (_, _) => { footer.IsEnabled = false; try { await Advance(); } finally { footer.IsEnabled = true; } };
        var layout = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto"), RowSpacing = 14, Margin = new Thickness(20, 40, 20, 20) };
        layout.Children.Add(header); Grid.SetRow(pageTitle, 1); layout.Children.Add(pageTitle);
        var scroll = new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(scroll, 2); layout.Children.Add(scroll);
        var bottom = Views.Stack(error, footer); Grid.SetRow(bottom, 3); layout.Children.Add(bottom); Content = layout;
    }

    internal async Task Advance()
    {
        error.IsVisible = false;
        try
        {
            if (step == 2)
            {
                settings.OnboardingCompleted = true; await configure(); completed(); Close(); return;
            }
            await configure(); step++; Render();
        }
        catch (Exception failure) { error.Text = failure.Message; error.IsVisible = true; }
    }
}
