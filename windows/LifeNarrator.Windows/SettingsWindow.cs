using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;

namespace LifeNarrator.Windows;

internal sealed class SettingsWindow : Window
{
    readonly Settings settings;
    readonly Texts text;
    readonly Companion? companion;
    readonly Func<Task> configure;
    readonly Func<Task<double>> testConnection;
    readonly Updater updater;
    readonly Func<Task> installUpdate;
    readonly Action<bool>? recording;
    readonly Func<Task>? quit;
    readonly Func<Task<string[]>>? ocrLanguages;
    StackPanel updateContent = new() { Spacing = 10 };
    readonly DockPanel root = new();
    readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, IsVisible = false };
    int tab;
    RulesView? rulesView;
    public const int SpriteTab = 0, AppearanceTab = 1, MemoryTab = 2, RulesTab = 3, ModelsTab = 4, GeneralTab = 5;

    public SettingsWindow(Settings settings, Func<Task> configure, Func<Task<double>> testConnection, Updater updater, Func<Task> installUpdate,
        Companion? companion = null, Action<bool>? recording = null, Func<Task<string[]>>? ocrLanguages = null, Func<Task>? quit = null)
    {
        this.companion = companion; this.recording = recording; this.ocrLanguages = ocrLanguages; this.quit = quit;
        if (companion != null) { companion.Changed += Refresh; Closed += (_, _) => companion.Changed -= Refresh; }
        this.settings = settings; this.configure = configure; this.testConnection = testConnection;
        this.updater = updater; this.installUpdate = installUpdate;
        updater.Changed += RefreshUpdates; Closed += (_, _) => updater.Changed -= RefreshUpdates;
        text = new Texts(settings);
        Width = 780; Height = 580; MinWidth = 780; MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        AutomationProperties.SetAutomationId(this, "settings");
        error.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        var dock = new DockPanel { LastChildFill = true };
        var status = new Border { Child = error, Padding = new Thickness(20, 4) };
        status.Bind(IsVisibleProperty, error.GetObservable(IsVisibleProperty));
        DockPanel.SetDock(status, Dock.Bottom); dock.Children.Add(status);
        dock.Children.Add(root); Content = dock; Render();
    }
    public void SelectTab(int index) { tab = index; Render(); }
    public void Refresh() => Render();
    public void ShowRuleInput() { SelectTab(RulesTab); Run(() => rulesView!.Edit(null)); }

    void Render()
    {
        Title = text["app.name"] + " · " + text["settings.title"];
        FontFamily = new FontFamily(settings.EffectiveLanguage == "zh" ? "Microsoft YaHei UI, Noto Sans CJK SC" : "Segoe UI, DejaVu Sans");
        root.Children.Clear();
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Height = 52 };
        var names = new[] { "tab.sprite", "appearance", "tab.memory", "rules", "models", "general" };
        var glyphs = new[] { "\uE734", "\uE790", "\uE8F1", "\uE8A5", "\uE99A", "\uE713" };
        var hues = new double[] { 320, 255, 175, 150, 200, 42 };
        for (var i = 0; i < names.Length; i++)
        {
            var index = i;
            var button = new ToggleButton { Content = Views.Horizontal(Views.Icon(glyphs[i]), Views.Label(text[names[i]])),
                IsChecked = tab == i, Padding = new Thickness(10, 6), CornerRadius = new CornerRadius(18), VerticalAlignment = VerticalAlignment.Center };
            button.Classes.Add("tab"); Views.Hue(button, hues[i]);
            AutomationProperties.SetAutomationId(button, "tab-" + i); AutomationProperties.SetName(button, text[names[i]]);
            button.Click += (_, _) => SelectTab(index); tabs.Children.Add(button);
        }
        DockPanel.SetDock(tabs, Dock.Top); root.Children.Add(tabs);
        Control content = tab switch
        {
            SpriteTab => Sprite(), AppearanceTab => Views.Card(text["appearance"], "\uE790", 255, null, Views.Caption(text["appearance.pending"])),
            MemoryTab => new MemoryView(settings, companion!, this, configure, Run, () => SelectTab(RulesTab)),
            RulesTab => rulesView = new RulesView(settings, companion!, this, configure, Run), ModelsTab => new ModelView(settings, configure, testConnection),
            _ => General()
        };
        if (content is StackPanel stack) stack.Spacing = 14;
        content.Margin = new Thickness(20);
        root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Name = "settings-scroll" });
    }
    Control Sprite()
    {
        var dutyHeading = Views.Row(Views.Heading(text["sprite.onDuty"], "\uE734"), Views.Horizontal(
            Views.Badge(settings.PauseShortcut?.ToString() ?? ""), Views.Switch(text["sprite.onDuty"], !settings.Paused, value => Run(async () =>
            { settings.Paused = !value; await configure(); }))));
        var levels = Views.Choices(new[] { ("quiet", "🤫"), ("lively", "🎉"), ("rowdy", "🔊") }.Select(p =>
            (p.Item1, p.Item2 + "  " + text["liveliness." + p.Item1], text["liveliness." + p.Item1 + ".hint"])), settings.Liveliness,
            id => Run(async () => { settings.Liveliness = id; await configure(); }));
        var pace = Views.Stack();
        void UpdatePace()
        {
            pace.Children.Clear();
            pace.Children.Add(Pace("pace.gap", settings.MarkGap, 30, value => settings.MarkGap = value, text["pace.gap.hint"]));
            pace.Children.Add(Views.Toggle(text["dwell.persistent"], settings.Persistent, value => Run(async () =>
            { settings.Persistent = value; UpdatePace(); await configure(); })));
            if (!settings.Persistent) pace.Children.Add(Pace("pace.dwell", settings.Dwell, 30, value => settings.Dwell = value));
            var dwellHint = Views.Caption("");
            void UpdateHint()
            {
                dwellHint.Text = text["pace.dwell.hint"].Replace("%.1f", (2.5 * settings.MaxOnScreen).ToString("0.0"));
                dwellHint.IsVisible = !settings.Persistent && settings.MaxOnScreen > 3;
            }
            UpdateHint(); pace.Children.Add(dwellHint);
            pace.Children.Add(Pace("pace.maxOnScreen", settings.MaxOnScreen, 10, value => { settings.MaxOnScreen = (int)value; UpdateHint(); }));
            pace.Children.Add(Views.Caption(text["pace.maxOnScreen.hint"]));
        }
        UpdatePace();
        var page = Views.Stack();
        if (companion != null) page.Children.Add(new GrowthCard(settings, companion, configure, Run));
        var ocr = Views.Caption(text["ocr.checking"]);
        page.Children.Add(Views.Card(text["ocr.title"], "\uE8D2", 42, null, ocr));
        Run(async () =>
        {
            var languages = ocrLanguages == null ? [] : await ocrLanguages();
            ocr.Text = languages.Length == 0 ? text["ocr.unavailable"] : text["ocr.ready"].Replace("%@", string.Join(", ", languages));
        });
        page.Children.Add(Views.Card(dutyHeading, 320, Views.Caption(text["sprite.onDuty.hint"])));
        page.Children.Add(Views.Card(text["liveliness"], "\uE767", 320, null, levels, Views.Caption(text["liveliness.hint"])));
        page.Children.Add(Views.Card(text["pace"], "\uE916", 320, text["pace.hint"], pace));
        page.Children.Add(Views.Card(text["persona"], "\uE77B", 320, text["persona.hint"], new PersonaView(settings, companion, this, configure, Run)));
        return page;
    }
    Control Pace(string key, double value, int max, Action<double> change, string? hint = null)
    {
        string Format(double v) => text[max == 10 ? "format.count" : "format.seconds"].Replace("%d", ((int)v).ToString());
        var badge = Views.Badge(Format(value));
        var slider = new Slider { Minimum = 1, Maximum = max, TickFrequency = 1, IsSnapToTickEnabled = true, SmallChange = 1, LargeChange = 1, Value = value };
        AutomationProperties.SetName(slider, text[key]); AutomationProperties.SetAutomationId(slider, key);
        slider.PropertyChanged += (_, e) =>
        {
            if (e.Property != Slider.ValueProperty) return;
            ((TextBlock)badge.Child!).Text = Format(slider.Value);
            Run(async () => { change(slider.Value); await configure(); });
        };
        var body = Views.Stack(Views.Row(Views.Label(text[key]), badge), slider); body.Spacing = 6;
        if (hint != null) body.Children.Add(Views.Caption(hint)); return body;
    }
    Control General()
    {
        var languages = new[] { "system", "zh", "en" };
        var language = new ComboBox { ItemsSource = new[] { text["language.system"], text["language.zhHans"], text["language.en"] },
            SelectedIndex = Array.IndexOf(languages, settings.Language), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(language, "language");
        language.SelectionChanged += (_, _) => Run(async () => { settings.Language = languages[language.SelectedIndex]; Render(); await configure(); });
        var startup = Views.Toggle(text["launchAtLogin"], settings.LaunchAtLogin, enabled => Run(async () =>
        { await Task.Run(() => Startup.SetEnabled(enabled)); settings.LaunchAtLogin = enabled; await configure(); }));
        var blacklist = new TextBox { Text = string.Join('\n', settings.Blacklist), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 90 };
        AutomationProperties.SetName(blacklist, text["blacklist"]); AutomationProperties.SetAutomationId(blacklist, "blacklist");
        blacklist.TextChanged += (_, _) => Run(async () =>
        { settings.Blacklist = (blacklist.Text ?? "").Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries); await configure(); });
        updateContent = Views.Stack(); RefreshUpdates();
        Control Recorder(string key, HotKey? value, Action<HotKey?> change) => Views.Row(Views.Label(text[key]),
            new ShortcutRecorder(text[key], value, text, shortcut => Run(async () => { change(shortcut); await configure(); }), recording));
        var github = Views.Button(text["github"], () => Views.OpenURL("https://github.com/zygs1083-dotcom/LifeNarrator"));
        Control aboutActions = quit == null ? github : Views.Row(github, Views.Button(text["quit"], () => Run(quit)));
        return Views.Stack(
            Views.Card(text["language"], "\uE774", 42, null, Views.Field(text["language"], language)),
            Views.Card(text["updates.title"], "\uE896", 42, null, updateContent),
            Views.Card(text["shortcuts"], "\uE765", 42, null,
                Recorder("shortcut.pause", settings.PauseShortcut, value => settings.PauseShortcut = value),
                Recorder("shortcut.chat", settings.ChatShortcut, value => settings.ChatShortcut = value),
                Recorder("shortcut.input", settings.InputShortcut, value => settings.InputShortcut = value)),
            Views.Card(text["blacklist"], "\uE8D8", 42, text["blacklist.hint"], blacklist),
            Views.Card(text["launchAtLogin"], "\uE7E8", 42, null, startup),
            Views.Card(text["about"], "\uE946", 42, null,
                Views.Horizontal(Views.Chip("\uE8F2"), Views.Label("LifeNarrator"), Views.Badge(text["version"] + " " + AppRelease.CurrentVersion)),
                aboutActions));
    }
    void RefreshUpdates()
    {
        updateContent.Children.Clear();
        updateContent.Children.Add(Views.Horizontal(Views.Label(text["version"]), Views.Label(AppRelease.CurrentVersion)));
        updateContent.Children.Add(Views.Toggle(text["updates.automatic"], settings.AutomaticUpdates, enabled => Run(async () =>
        { settings.AutomaticUpdates = enabled; updater.Configure(enabled); await configure(); })));
        var message = updater.State switch
        {
            UpdateState.Checking => text["updates.checking"], UpdateState.UpToDate => text["updates.latest"],
            UpdateState.Available => text["updates.available"].Replace("%@", updater.Release!.Tag),
            UpdateState.Downloading => text["updates.downloading"].Replace("%d", updater.Progress.ToString()).Replace("%%", "%"),
            UpdateState.Failed => updater.Error!, _ => ""
        };
        if (message.Length > 0) updateContent.Children.Add(Views.Label(message));
        if (updater.State == UpdateState.Available)
        {
            var install = Views.Primary(text["updates.install"], () => Run(installUpdate));
            AutomationProperties.SetAutomationId(install, "updates-install"); updateContent.Children.Add(install);
        }
        var check = Views.Button(text["updates.check"], () => Run(updater.Check)); check.IsEnabled = !updater.IsBusy;
        AutomationProperties.SetAutomationId(check, "updates-check"); updateContent.Children.Add(check);
    }
    async void Run(Func<Task> action)
    {
        try { await action(); error.IsVisible = false; }
        catch (Exception failure) { error.Text = failure.Message; error.IsVisible = true; }
    }
}
