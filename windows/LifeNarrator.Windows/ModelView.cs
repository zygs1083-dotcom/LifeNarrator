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
        text = new Texts(settings); Spacing = 10;
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
        Children.Clear(); Children.Add(Views.Card(text["provider"], body));
    }

    internal Control ModelChoices() => Views.Choices([
        ("api", text["provider.api"], text["provider.api.hint"]),
        ("none", text["provider.none"], text["provider.none.hint"]),
        ("builtin", text["provider.builtin"], text["provider.builtin.hint"])], settings.Provider.Kind,
        id => Run(async () => { settings.Provider.Kind = id; await configure(); }),
        selectionChanged: Render);

    readonly List<Action> downloadRefresh = [];
    void RefreshDownloads() { foreach (var refresh in downloadRefresh) refresh(); }

    Control BuiltinEditor()
    {
        var body = Views.Stack(Views.Caption(text["model.windows.hint"]));
        body.Children.Add(Views.Choices(settings.Downloaders.Select((d, i) =>
            (d.Model.Name, text[i == 0 ? "model.standard" : "model.fast"], (d.Model.Size >= 1e9 ? $"{d.Model.Size / 1e9:0.00} GB · " : $"{d.Model.Size / 1e6:0.00} MB · ") + text[i == 0 ? "model.standard.hint" : "model.fast.hint"])),
            settings.BuiltinModel, name => Run(async () => { settings.BuiltinModel = name; await configure(); }), selectionChanged: Render));
        foreach (var download in settings.Downloaders)
        {
            var source = new ComboBox { ItemsSource = new[] { "huggingface.co", "hf-mirror.com" },
                SelectedItem = download.Source, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(source, text["model.source"]);
            source.SelectionChanged += (_, _) => download.Source = (string)source.SelectedItem!;
            var status = Views.Label("");
            var progress = new ProgressBar { Minimum = 0, Maximum = 100, Height = 6 };
            AutomationProperties.SetName(progress, download.Model.Name);
            var start = Views.Button(text["model.download"], () => Run(async () =>
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
                download.Delete(); await configure();
            }));
            AutomationProperties.SetAutomationId(start, "download-" + download.Model.Name);
            AutomationProperties.SetAutomationId(pause, "pause-" + download.Model.Name);
            AutomationProperties.SetAutomationId(delete, "delete-" + download.Model.Name);
            var failure = Views.Label("");
            failure.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
            void Refresh()
            {
                var state = download.State;
                status.Text = text[state switch
                {
                    ModelDownloadState.Downloading => "model.downloading",
                    ModelDownloadState.Verifying => "model.verifying",
                    ModelDownloadState.Ready => "model.ready",
                    _ => "model.notDownloaded"
                }] + (state == ModelDownloadState.Downloading ? $" {download.Progress:P0}" : "");
                progress.Value = download.Progress * 100;
                progress.IsIndeterminate = state == ModelDownloadState.Verifying;
                progress.IsVisible = state is ModelDownloadState.Downloading or ModelDownloadState.Verifying;
                source.IsVisible = start.IsVisible = state == ModelDownloadState.NotDownloaded;
                start.Content = text[download.HasPartial ? "model.resume" : "model.download"];
                pause.IsVisible = state == ModelDownloadState.Downloading;
                delete.IsVisible = state == ModelDownloadState.Ready || (state == ModelDownloadState.NotDownloaded && download.HasPartial);
                failure.Text = download.Error; failure.IsVisible = download.Error != null;
            }
            downloadRefresh.Add(Refresh); Refresh();
            body.Children.Add(Views.Card(download.Model.Name, status, progress, source, Views.Row(start, Views.Row(pause, delete)), failure));
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
        var key = new TextBox { PasswordChar = '●', Text = CredentialStore.Read(preset.Id) };
        AutomationProperties.SetName(key, text["api.key"]); AutomationProperties.SetAutomationId(key, "api-key");
        var saved = Views.Caption("");
        body.Children.Add(Views.Field(text["api.key"], key));
        body.Children.Add(Views.Row(Views.Button(text["api.saveKey"], () => Run(async () =>
        {
            CredentialStore.Write(preset.Id, key.Text ?? "");
            saved.Text = text["api.keySaved"]; await configure();
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
        var test = Views.Button(text["api.test"], () => { });
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
