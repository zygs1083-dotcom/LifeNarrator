using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class ModelView : StackPanel
{
    readonly Settings settings;
    readonly Texts text;
    readonly Func<Task> configure;
    readonly Func<Task<double>> testConnection;
    readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, IsVisible = false };
    public ModelView(Settings settings, Func<Task> configure, Func<Task<double>> testConnection)
    {
        this.settings = settings; this.configure = configure; this.testConnection = testConnection;
        text = new Texts(settings); Spacing = 14;
        error.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        Render();
        AttachedToVisualTree += (_, _) => { foreach (var download in settings.Downloaders) download.Changed += RefreshDownloads; RefreshDownloads(); };
        DetachedFromVisualTree += (_, _) => { foreach (var download in settings.Downloaders) download.Changed -= RefreshDownloads; };
    }
    void Render()
    {
        downloadRefresh.Clear();
        var body = Views.Stack(ModelChoices());
        if (settings.Provider.Kind == "api") body.Children.Add(ProviderEditor());
        if (settings.Provider.Kind == "builtin") body.Children.Add(BuiltinEditor());
        Children.Clear(); Children.Add(Views.Card(text["provider"], "\uE99A", 200, null, body));
        var systemOne = Views.Stack(Views.Toggle(text["systemOne.enable"], settings.SystemOne != null, enabled => Run(async () =>
        { settings.SystemOne = enabled ? new SystemOneSettings() : null; Render(); await configure(); })));
        if (settings.SystemOne is { } connection)
        {
            systemOne.Children.Add(Field("api.baseURL", connection.BaseURL, value => connection.BaseURL = value, "system-one-url"));
            systemOne.Children.Add(Field("api.model", connection.Model, value => connection.Model = value, "system-one-model"));
            var key = new TextBox { PasswordChar = '●' };
            key.AttachedToVisualTree += (_, _) => Run(async () => key.Text = await Task.Run(() => CredentialStore.Read("systemOne")));
            systemOne.Children.Add(Views.Field(text["api.key"], key));
            var saved = Views.Badge(text["api.keySaved"], 150); saved.IsVisible = false;
            key.TextChanged += (_, _) => saved.IsVisible = false;
            systemOne.Children.Add(Views.Row(Views.Primary(text["api.saveKey"], () => Run(async () =>
            { var value = key.Text ?? ""; await Task.Run(() => CredentialStore.Write("systemOne", value)); saved.IsVisible = true; await configure(); })), saved));
        }
        Children.Add(Views.Card(text["systemOne"], "\uE968", 200, null, systemOne));
    }

    internal Control ModelChoices() => Views.Choices([
        ("builtin", "📦  " + text["provider.builtin"], text["provider.builtin.hint"]),
        ("api", "☁️  " + text["provider.api"], text["provider.api.hint"]),
        ("none", "🚫  " + text["provider.none"], text["provider.none.hint"])], settings.Provider.Kind,
        id => Run(async () => { settings.Provider.Kind = id; await configure(); }),
        selectionChanged: Render);

    readonly List<Action> downloadRefresh = [];
    void RefreshDownloads() { foreach (var refresh in downloadRefresh) refresh(); }

    Control BuiltinEditor()
    {
        var body = Views.Stack();
        foreach (var download in settings.Downloaders)
        {
            var source = new ComboBox { ItemsSource = new[] { "huggingface.co", "hf-mirror.com" },
                SelectedItem = download.Source, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(source, text["model.source"]);
            source.SelectionChanged += (_, _) => download.Source = (string)source.SelectedItem!;
            var sourceField = Views.Field(text["model.source"], source);
            var status = Views.Badge("", 42);
            var statusText = (TextBlock)status.Child!;
            var progress = new ProgressBar { Minimum = 0, Maximum = 100, Height = 6 };
            AutomationProperties.SetName(progress, download.Model.Name);
            var start = Views.Primary(text["model.download"], () => Run(async () =>
            {
                await download.Start(download.Model.FromSource(download.Source));
                if (download.State == ModelDownloadState.Ready && settings.Provider.Kind == "builtin" && settings.BuiltinModel == download.Model.Name)
                    await configure();
            }));
            var pause = Views.Button(text["model.pause"], () => Run(download.Pause));
            var delete = Views.Button(text["delete"], () => Run(async () =>
            {
                if (settings.Provider.Kind == "builtin" && settings.BuiltinModel == download.Model.Name)
                {
                    var configuration = settings.Provider.Kind;
                    settings.Provider.Kind = "none";
                    try { await configure(); }
                    finally { settings.Provider.Kind = configuration; }
                }
                await Task.Run(download.Delete); await configure();
            }));
            AutomationProperties.SetAutomationId(start, "download-" + download.Model.Name);
            AutomationProperties.SetAutomationId(pause, "pause-" + download.Model.Name);
            AutomationProperties.SetAutomationId(delete, "delete-" + download.Model.Name);
            var failure = Views.Label("");
            failure.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
            void Refresh()
            {
                var state = download.State;
                statusText.Text = text[state switch
                {
                    ModelDownloadState.Downloading => "model.downloading",
                    ModelDownloadState.Verifying => "model.verifying",
                    ModelDownloadState.Ready => "model.ready",
                    _ => "model.notDownloaded"
                }] + (state == ModelDownloadState.Downloading ? $" {download.Progress:P0}" : "");
                progress.Value = download.Progress * 100;
                progress.IsIndeterminate = state == ModelDownloadState.Verifying;
                progress.IsVisible = state is ModelDownloadState.Downloading or ModelDownloadState.Verifying;
                sourceField.IsVisible = start.IsVisible = state == ModelDownloadState.NotDownloaded;
                start.Content = text[download.HasPartial ? "model.resume" : "model.download"];
                pause.IsVisible = state == ModelDownloadState.Downloading;
                delete.IsVisible = state == ModelDownloadState.Ready || (state == ModelDownloadState.NotDownloaded && download.HasPartial);
                failure.Text = download.Error; failure.IsVisible = download.Error != null;
            }
            downloadRefresh.Add(Refresh); Refresh();
            var index = Array.IndexOf(settings.Downloaders, download);
            var select = Views.Button(text[index == 0 ? "model.standard" : "model.fast"], () => Run(async () =>
            { settings.BuiltinModel = download.Model.Name; Render(); await configure(); }));
            select.Content = Views.Row(Views.Label((settings.BuiltinModel == download.Model.Name ? "● " : "○ ") + text[index == 0 ? "model.standard" : "model.fast"]),
                Views.Caption(download.Model.Size >= 1e9 ? $"{download.Model.Size / 1e9:0.00} GB" : $"{download.Model.Size / 1e6:0.00} MB"));
            select.HorizontalAlignment = HorizontalAlignment.Stretch; select.BorderThickness = new Thickness(0); select.Padding = new Thickness(0); select.Background = Brushes.Transparent;
            AutomationProperties.SetAutomationId(select, "choice-" + download.Model.Name);
            var card = new Border { Padding = new Thickness(10), CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1),
                Child = Views.Stack(select, Views.Caption(text[index == 0 ? "model.standard.hint" : "model.fast.hint"]),
                    Views.Row(Views.Label(download.Model.Name), status), progress, sourceField, Views.Row(start, Views.Horizontal(pause, delete)), failure) };
            card.Bind(Border.BorderBrushProperty, this.GetResourceObservable(settings.BuiltinModel == download.Model.Name ? "Accent" : "Stroke"));
            ((StackPanel)card.Child!).Spacing = 8;
            body.Children.Add(card);
        }
        return body;
    }

    internal Control ProviderEditor()
    {
        var preset = Catalog.Providers.Single(p => p.Id == settings.Provider.PresetId);
        var providers = new List<ComboBoxItem>();
        foreach (var group in new[] { "cn", "global", "local", "custom" })
        {
            providers.Add(new ComboBoxItem { Content = text["api.group." + group], IsEnabled = false, FontWeight = FontWeight.Bold });
            providers.AddRange(Catalog.Providers.Where(p => p.Group == group).Select(p =>
                new ComboBoxItem { Content = p.Name.Text(settings.EffectiveLanguage), Tag = p.Id }));
        }
        var selector = new ComboBox { ItemsSource = providers, SelectedItem = providers.Single(p => Equals(p.Tag, preset.Id)),
            HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(selector, text["api.provider"]); AutomationProperties.SetAutomationId(selector, "provider");
        selector.SelectionChanged += (_, _) =>
        {
            var chosen = Catalog.Providers.Single(p => p.Id == (string)((ComboBoxItem)selector.SelectedItem!).Tag!);
            Run(async () =>
            {
                settings.Provider = new ProviderSettings { Kind = "api", PresetId = chosen.Id,
                    Model = chosen.SuggestedModels.FirstOrDefault() ?? "" };
                Render(); await configure();
            });
        };
        var model = Field("api.model", settings.Provider.Model, value => settings.Provider.Model = value, "model");
        var body = Views.Stack(Views.Field(text["api.provider"], selector), model);
        if (preset.SuggestedModels.Length > 0) body.Children.Add(Views.Caption(text["api.suggestions"] + ": " + string.Join(", ", preset.SuggestedModels)));
        var key = new TextBox { PasswordChar = '●' };
        key.AttachedToVisualTree += (_, _) => Run(async () => { key.Text = await Task.Run(() => CredentialStore.Read(preset.Id)); });
        AutomationProperties.SetName(key, text["api.key"]); AutomationProperties.SetAutomationId(key, "api-key");
        var saved = Views.Badge(text["api.keySaved"], 150); saved.IsVisible = false;
        key.TextChanged += (_, _) => saved.IsVisible = false;
        body.Children.Add(Views.Field(text["api.key"], key));
        body.Children.Add(Views.Row(Views.Primary(text["api.saveKey"], () => Run(async () =>
        {
            var value = key.Text ?? "";
            await Task.Run(() => CredentialStore.Write(preset.Id, value));
            saved.IsVisible = true; await configure();
        })), saved));
        if (preset.KeyURL != null) body.Children.Add(Views.Button(text["api.getKey"], () => Views.OpenURL(preset.KeyURL)));
        var advanced = Views.Stack(Field("api.baseURL", settings.Provider.BaseURL ?? preset.BaseURL,
            value => settings.Provider.BaseURL = value.Length == 0 ? null : value, "base-url"));
        if (preset.Api == "openai")
        {
            var modes = new[] { "", "json_schema", "json_object", "prompt" };
            var structured = new ComboBox { ItemsSource = modes.Select(mode => new ComboBoxItem { Content = mode == "" ? text["api.default"] : mode, Tag = mode }).ToArray(),
                SelectedIndex = Array.IndexOf(modes, settings.Provider.Structured ?? ""), HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(structured, text["api.structured"]);
            structured.SelectionChanged += (_, _) => Run(async () =>
            { settings.Provider.Structured = modes[structured.SelectedIndex] is "" ? null : modes[structured.SelectedIndex]; await configure(); });
            advanced.Children.Add(Views.Field(text["api.structured"], structured));
        }
        advanced.IsVisible = false;
        body.Children.Add(Views.Button(text["api.advanced"] + "  ⌄", () => advanced.IsVisible = !advanced.IsVisible));
        body.Children.Add(advanced);
        body.Children.Add(Views.Toggle(text["api.vision"], settings.Provider.Vision, enabled => Run(async () =>
        { settings.Provider.Vision = enabled; await configure(); })));
        body.Children.Add(Views.Caption(text["api.vision.hint"]));
        var result = Views.Caption("");
        var test = Views.Primary(text["api.test"], () => { });
        AutomationProperties.SetAutomationId(test, "test-connection");
        test.Click += async (_, _) =>
        {
            test.IsEnabled = false; result.Text = text["testing"];
            try { result.Text = text["api.testSuccess"] + $" · {await testConnection():0} ms"; }
            catch (Exception failure) { result.Text = failure.Message; ShowError(failure); }
            finally { test.IsEnabled = true; }
        };
        body.Children.Add(Views.Row(test, result));
        if (preset.Group != "local") body.Children.Add(Views.Caption(text["api.privacy"]));
        return body;
    }

    Control Field(string label, string value, Action<string> change, string id)
    {
        var input = new TextBox { Text = value };
        AutomationProperties.SetName(input, text[label]); AutomationProperties.SetAutomationId(input, id);
        input.TextChanged += (_, _) => Run(async () => { change(input.Text ?? ""); await configure(); });
        return Views.Field(text[label], input);
    }


    async void Run(Func<Task> action)
    {
        try { await action(); error.IsVisible = false; }
        catch (Exception failure) { ShowError(failure); }
    }
    void ShowError(Exception failure)
    {
        error.Text = failure.Message; error.IsVisible = true;
        if (!Children.Contains(error)) Children.Add(error);
    }
}
