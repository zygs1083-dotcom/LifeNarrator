using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class SettingsWindow : Window
{
    readonly Settings settings;
    readonly Texts text;
    readonly Func<Task> configure;
    readonly Func<Task<double>> testConnection;
    readonly Updater updater;
    readonly Func<Task> installUpdate;
    StackPanel updateContent = new() { Spacing = 10 };
    readonly DockPanel root = new() { Margin = new Thickness(20) };
    readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, IsVisible = false };
    int tab;

    public SettingsWindow(Settings settings, Func<Task> configure, Func<Task<double>> testConnection, Updater updater, Func<Task> installUpdate)
    {
        this.settings = settings; this.configure = configure; this.testConnection = testConnection;
        this.updater = updater; this.installUpdate = installUpdate;
        updater.Changed += RefreshUpdates;
        Closed += (_, _) => updater.Changed -= RefreshUpdates;
        text = new Texts(settings);
        Width = 780; Height = 660; MinWidth = 640; MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        AutomationProperties.SetAutomationId(this, "settings");
        error.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        var dock = new DockPanel { LastChildFill = true };
        var status = new Border { Child = error, Padding = new Thickness(20, 4) };
        DockPanel.SetDock(status, Dock.Bottom); dock.Children.Add(status);
        dock.Children.Add(root); Content = dock;
        Render();
    }

    public void SelectTab(int index) { tab = index; Render(); }
    public void Refresh() => Render();

    void Render()
    {
        Title = text["app.name"] + " · " + text["settings"];
        root.Children.Clear();
        var tabs = Views.Choices([
            ("0", text["tab.sprite"], ""), ("1", text["models"], ""), ("2", text["general"], "")],
            tab.ToString(), id => { tab = int.Parse(id); Render(); }, tabs: true);
        DockPanel.SetDock(tabs, Dock.Top); root.Children.Add(tabs);
        Control content = tab switch { 0 => Sprite(), 1 => new ModelView(settings, configure, testConnection), _ => General() };
        root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
    }

    Control Sprite()
    {
        var duty = Views.Toggle(text["sprite.onDuty"], !settings.Paused, value => Run(async () =>
        { settings.Paused = !value; await configure(); }));
        var levels = Views.Choices(new[] { "quiet", "lively", "rowdy" }.Select(id =>
            (id, text["liveliness." + id], text["liveliness." + id + ".hint"])), settings.Liveliness,
            id => Run(async () => { settings.Liveliness = id; await configure(); }));
        var personas = Views.Choices(Catalog.Personas.Select(p => (p.Id, p.Emoji + "  " + p.Name.Text(settings.EffectiveLanguage),
            p.Caption.Text(settings.EffectiveLanguage))), settings.Persona,
            id => Run(async () => { settings.Persona = id; await configure(); }));
        return Views.Stack(
            Views.Card(text["sprite.onDuty"], duty, Views.Caption(text["sprite.onDuty.hint"])),
            Views.Card(text["liveliness"], levels, Views.Caption(text["liveliness.hint"])),
            Views.Card(text["persona"], personas),
            Views.Card(text["pace"], Views.Caption(text["pace.hint"]),
                Pace("pace.gap", settings.MarkGap, 30, value => settings.MarkGap = value),
                Pace("pace.dwell", settings.Dwell, 30, value => settings.Dwell = value),
                Pace("pace.maxOnScreen", settings.MaxOnScreen, 10, value => settings.MaxOnScreen = (int)value)));
    }

    Control Pace(string key, double value, int max, Action<double> change)
    {
        var badge = Views.Caption(Format(value));
        string Format(double v) => text[max == 10 ? "format.count" : "format.seconds"].Replace("%d", ((int)v).ToString());
        var slider = new Slider { Minimum = 1, Maximum = max, TickFrequency = 1,
            IsSnapToTickEnabled = true, SmallChange = 1, LargeChange = 1, Value = value };
        AutomationProperties.SetName(slider, text[key]); AutomationProperties.SetAutomationId(slider, key);
        slider.PropertyChanged += (_, e) =>
        {
            if (e.Property != Slider.ValueProperty) return;
            badge.Text = Format(slider.Value);
            Run(async () => { change(slider.Value); await configure(); });
        };
        return Views.Stack(Views.Row(Views.Label(text[key]), badge), slider);
    }

    Control General()
    {
        var languages = new[] { "system", "zh", "en" };
        var language = new ComboBox { ItemsSource = new[] { text["language.system"], text["language.zhHans"], text["language.en"] },
            SelectedIndex = Array.IndexOf(languages, settings.Language), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(language, text["language"]); AutomationProperties.SetAutomationId(language, "language");
        language.SelectionChanged += (_, _) => Run(async () =>
        { settings.Language = languages[language.SelectedIndex]; Render(); await configure(); });
        var startup = Views.Toggle(text["launchAtLogin"], settings.LaunchAtLogin, enabled => Run(async () =>
        { Startup.SetEnabled(enabled); settings.LaunchAtLogin = enabled; await configure(); }));
        var blacklist = new TextBox { Text = string.Join('\n', settings.Blacklist), AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, Height = 90 };
        AutomationProperties.SetName(blacklist, text["blacklist"]); AutomationProperties.SetAutomationId(blacklist, "blacklist");
        blacklist.TextChanged += (_, _) => Run(async () =>
        { settings.Blacklist = (blacklist.Text ?? "").Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries); await configure(); });
        updateContent = Views.Stack();
        RefreshUpdates();
        return Views.Stack(Views.Card(text["language"], language, startup),
            Views.Card(text["blacklist"], Views.Caption(text["blacklist.hint"]), blacklist),
            Views.Card(text["updates.title"], updateContent),
            Views.Card(text["about"], Views.Label("LifeNarrator"),
                Views.Button(text["github"], () => Views.OpenURL("https://github.com/zygs1083-dotcom/LifeNarrator"))));
    }

    void RefreshUpdates()
    {
        updateContent.Children.Clear();
        updateContent.Children.Add(Views.Caption(text["version"] + " " + AppRelease.CurrentVersion));
        updateContent.Children.Add(Views.Toggle(text["updates.automatic"], settings.AutomaticUpdates, enabled => Run(async () =>
        { settings.AutomaticUpdates = enabled; updater.Configure(enabled); await configure(); })));
        var check = Views.Button(text["updates.check"], () => Run(updater.Check));
        check.IsEnabled = !updater.IsBusy;
        AutomationProperties.SetAutomationId(check, "updates-check");
        updateContent.Children.Add(check);
        var message = updater.State switch
        {
            UpdateState.Checking => text["updates.checking"],
            UpdateState.UpToDate => text["updates.latest"],
            UpdateState.Available => text["updates.available"].Replace("%@", updater.Release!.Tag),
            UpdateState.Downloading => text["updates.downloading"].Replace("%d", updater.Progress.ToString()),
            UpdateState.Failed => updater.Error!,
            _ => ""
        };
        if (message.Length > 0) updateContent.Children.Add(Views.Label(message));
        if (updater.State == UpdateState.Available)
        {
            var install = Views.Button(text["updates.install"], () => Run(installUpdate));
            AutomationProperties.SetAutomationId(install, "updates-install");
            updateContent.Children.Add(install);
        }
    }

    async void Run(Func<Task> action)
    {
        try { await action(); error.IsVisible = false; }
        catch (Exception failure) { ShowError(failure); }
    }
    void ShowError(Exception failure) { error.Text = failure.Message; error.IsVisible = true; }
}

internal static class Views
{
    public static StackPanel Stack(params Control[] controls)
    {
        var stack = new StackPanel { Spacing = 10 };
        foreach (var control in controls) stack.Children.Add(control);
        return stack;
    }
    public static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
    public static TextBlock Caption(string text) { var label = Label(text); label.Classes.Add("caption"); return label; }
    public static Border Card(string title, params Control[] controls)
    {
        var heading = Label(title); heading.FontSize = 15; heading.FontWeight = FontWeight.SemiBold;
        var body = Stack(heading);
        foreach (var control in controls) body.Children.Add(control);
        var card = new Border { Child = body, Margin = new Thickness(0, 0, 0, 4) }; card.Classes.Add("card"); return card;
    }
    public static Grid Row(Control left, Control right)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        left.VerticalAlignment = right.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(right, 1); grid.Children.Add(left); grid.Children.Add(right); return grid;
    }
    public static Control Field(string title, Control control) => Stack(Label(title), control);
    public static Button Button(string title, Action action)
    {
        var button = new Button { Content = title }; button.Click += (_, _) => action(); return button;
    }
    public static Control Toggle(string title, bool selected, Action<bool> change)
    {
        var toggle = new ToggleButton { Content = selected ? "●" : "○", IsChecked = selected, MinWidth = 48 };
        AutomationProperties.SetName(toggle, title);
        toggle.Click += (_, _) => { toggle.Content = toggle.IsChecked == true ? "●" : "○"; change(toggle.IsChecked == true); };
        return Row(Label(title), toggle);
    }
    public static Control Choices(IEnumerable<(string Id, string Title, string Caption)> options, string selection,
        Action<string> change, string? disabled = null, bool tabs = false, Action? selectionChanged = null)
    {
        var panel = new WrapPanel { Orientation = Orientation.Horizontal };
        var buttons = new List<(string Id, ToggleButton Button)>();
        foreach (var option in options)
        {
            var button = new ToggleButton { Content = option.Caption.Length == 0 ? Label(option.Title) : Stack(Label(option.Title), Caption(option.Caption)),
                CornerRadius = new CornerRadius(tabs ? 18 : 14),
                IsChecked = selection == option.Id, IsEnabled = option.Id != disabled, Width = tabs ? 155 : 210,
                Margin = new Thickness(0, 0, 8, 8), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(button, option.Title); AutomationProperties.SetAutomationId(button, (tabs ? "tab-" : "choice-") + option.Id);
            if (tabs) { button.Classes.Add("tab"); if (option.Id == "1") button.Classes.Add("sky"); if (option.Id == "2") button.Classes.Add("honey"); }
            buttons.Add((option.Id, button));
            button.Click += (_, _) =>
            {
                foreach (var item in buttons) item.Button.IsChecked = item.Id == option.Id;
                change(option.Id); selectionChanged?.Invoke();
            };
            panel.Children.Add(button);
        }
        return panel;
    }
    public static void OpenURL(string url) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
}
