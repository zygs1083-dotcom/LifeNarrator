using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading.Channels;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;

namespace LifeNarrator.Windows;

public sealed partial class ShellApp : Application
{
    IClassicDesktopStyleApplicationLifetime desktop = null!;
    Settings settings = null!;
    TrayIcon tray = null!;
    NativeMenuItem status = null!, pause = null!, restart = null!, details = null!, ocrHint = null!;
    readonly Dictionary<string, NativeMenuItem> levels = new(), personas = new();
    BrainClient? brain;
    ContextSensor? sensor;
    WindowEvents? events;
    OverlayController? overlay;
    Channel<(string Method, object Params)>? changes;
    Task? eventPump;
    SettingsWindow? settingsWindow;
    ChatWindow? chatWindow;
    ChatHotKey? chatHotKey;
    Companion companion = null!;
    NativeMenuItem identity = null!, chatItem = null!;
    OnboardingWindow? onboarding;
    readonly SemaphoreSlim configurationGate = new(1);
    Texts text = null!;
    Updater updater = null!;
    NativeMenuItem updateItem = null!, updateFailureItem = null!;
    UpdateFailure? updateFailure;
    NativeMenuItem settingsItem = null!, quit = null!, levelHeader = null!, personaHeader = null!;
    public override void Initialize() => Styles.Add(new AppTheme());
    bool exiting;
    bool stopping;
    string? error;

    public override async void OnFrameworkInitializationCompleted()
    {
        desktop = (IClassicDesktopStyleApplicationLifetime)ApplicationLifetime!;
        desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        settings = await Task.Run(Settings.Load);
        text = new Texts(settings);
        companion = new Companion((method, parameters) => brain!.Call(method, parameters));
        companion.Changed += UpdateTray;
        identity = new NativeMenuItem { IsEnabled = false };
        chatItem = Item(text["chat.open"], () => ShowChat());
        updater = new Updater(Program.VerifyUpdate ? new Uri(Environment.GetEnvironmentVariable("LIFENARRATOR_UPDATE_RELEASES")!) : null);

        updater.Changed += UpdateTray;
        status = new NativeMenuItem { Header = "人生旁白", IsEnabled = false };
        details = new NativeMenuItem { Header = "错误详情", IsVisible = false };
        pause = Item("在岗", async () => { settings.Paused = !settings.Paused; await Configure(); settingsWindow?.Refresh(); });
        var levelMenu = new NativeMenu();
        foreach (var (id, label) in new[] { ("quiet", "安静"), ("lively", "热闹"), ("rowdy", "吵闹") })
        {
            var item = Item(label, async () => { settings.Liveliness = id; await Configure(); settingsWindow?.Refresh(); });
            item.ToggleType = NativeMenuItemToggleType.Radio;
            levels.Add(id, item); levelMenu.Items.Add(item);
        }
        var personaMenu = new NativeMenu();
        foreach (var (id, label) in new[] { ("sharp", "毒舌"), ("gentle", "温柔"), ("chuuni", "中二"),
            ("teacher", "老师"), ("mom", "妈妈"), ("hype", "捧场"), ("cat", "猫咪") })
        {
            var item = Item(label, async () => { settings.Persona = id; await Configure(); settingsWindow?.Refresh(); });
            item.ToggleType = NativeMenuItemToggleType.Radio;
            personas.Add(id, item); personaMenu.Items.Add(item);
        }
        restart = Item("重启大脑", async () => { await Stop(); await Start(); });
        ocrHint = new NativeMenuItem("OCR 不可用：请在 Windows 设置中安装简体中文或英语（美国）OCR 语言")
            { IsEnabled = false, IsVisible = false };
        var menu = new NativeMenu();
        menu.Items.Add(identity); menu.Items.Add(chatItem); menu.Items.Add(status); menu.Items.Add(details); menu.Items.Add(ocrHint); menu.Items.Add(pause);
        levelHeader = new NativeMenuItem("热闹程度") { Menu = levelMenu }; menu.Items.Add(levelHeader);
        personaHeader = new NativeMenuItem("人格") { Menu = personaMenu }; menu.Items.Add(personaHeader);
        menu.Items.Add(restart); menu.Items.Add(new NativeMenuItemSeparator());
        settingsItem = Item("设置…", () => { ShowSettings(); return Task.CompletedTask; }); menu.Items.Add(settingsItem);
        updateItem = Item("", () => { ShowSettings(); settingsWindow?.SelectTab(SettingsWindow.GeneralTab); return Task.CompletedTask; });
        menu.Items.Add(updateItem);
        updateFailureItem = Item("", () => { Views.OpenURL(updateFailure!.LogPath); return Task.CompletedTask; });
        menu.Items.Add(updateFailureItem);
        quit = Item("退出", Quit); menu.Items.Add(quit);
        tray = new TrayIcon { Menu = menu, ToolTipText = "人生旁白", Icon = MakeIcon(42, 166, 100), IsVisible = true };
        tray.Clicked += (_, _) => ShowSettings();
        var show = new EventWaitHandle(false, EventResetMode.AutoReset, Program.ShowSettingsEvent);
        new Thread(() => { while (show.WaitOne()) Dispatcher.UIThread.Post(ShowSettings); }) { IsBackground = true }.Start();
        TrayIcon.SetIcons(this, new TrayIcons { tray });
        Dispatcher.UIThread.Post(async () =>
        {
            try
            {
                await Task.Run(() => { Startup.SetEnabled(settings.LaunchAtLogin); _ = settings.Downloaders; updateFailure = updater.PreviousFailure(); });
                await Start();
                updater.Configure(settings.AutomaticUpdates && !Program.VerifyUI && !Program.VerifyUpdate && !Program.VerifyUpdateResult);
                if (!settings.OnboardingCompleted)
                {
                    onboarding = new OnboardingWindow(settings, Configure, TestConnection, ShowSettings);
                    onboarding.Closed += (_, _) => onboarding = null;
                    onboarding.Show();
                }
                if (Program.VerifyUI) await VerifyUI();
                if (Program.VerifyCompanion) await VerifyCompanion();
                if (Program.VerifyUpdate) await VerifyUpdate();
                if (Program.VerifyUpdateResult) await VerifyUpdateResult();
            }
            catch (Exception failure) { Report(failure.Message); if (Program.VerifyUI || Program.VerifyCompanion) desktop.Shutdown(1); }
        });
        base.OnFrameworkInitializationCompleted();
    }

    NativeMenuItem Item(string header, Func<Task> action)
    {
        var item = new NativeMenuItem(header);
        item.Click += async (_, _) =>
        {
            try { await action(); }
            catch (Exception failure) { Report(failure.Message); }
        };
        return item;
    }

    async Task Start()
    {
        stopping = false;
        error = null;
        UpdateTray();
        overlay = new OverlayController(settings, Report, companion, (narration, point) => OpenChat(narration, point));
        chatHotKey = new ChatHotKey(settings, async () =>
        { try { settings.Paused = !settings.Paused; await Configure(); settingsWindow?.Refresh(); } catch (Exception failure) { Report(failure.Message); } },
            () => OpenChat(), () => { ShowSettings(); settingsWindow?.ShowRuleInput(); });
        var channel = Channel.CreateUnbounded<(string, object)>(new UnboundedChannelOptions { SingleReader = true });
        changes = channel;
        var input = new WindowEvents(() => sensor?.RequestRead(),
            wheel => Dispatcher.UIThread.Post(() => overlay?.Scrolled(wheel)));
        events = input;
        sensor = new ContextSensor(overlay.Displays,
            (method, p) => channel.Writer.TryWrite((method, p)),
            message => Dispatcher.UIThread.Post(() => Report(message)), () => input.LastTypedAt, () => input.ScrollAt,
            () => Dispatcher.UIThread.Post(() => overlay?.Scrolled(true)),
            unavailable => Dispatcher.UIThread.Post(() => ocrHint.IsVisible = unavailable));
        overlay.Sensor = sensor;
        brain = new BrainClient(Path.Combine(AppContext.BaseDirectory, "brain", "narrator-brain.exe"),
            Path.Combine(Settings.DataDirectory, "brain.log"), Port,
            message => Dispatcher.UIThread.Post(() => { overlay?.DismissAll(); Report(message); }));
        await brain.Call("configure", await Task.Run(settings.Configuration));
        await companion.Refresh();
        eventPump = Pump(changes.Reader, brain);
    }

    async Task Pump(ChannelReader<(string Method, object Params)> reader, BrainClient client)
    {
        try
        {
            await foreach (var change in reader.ReadAllAsync()) await client.Call(change.Method, change.Params);
        }
        catch (Exception failure) { if (!exiting && !stopping) Dispatcher.UIThread.Post(() => Report(failure.Message)); }
    }

    async Task<object?> Port(string method, System.Text.Json.JsonElement parameters)
    {
        if (method.StartsWith("sensor.")) return await sensor!.Call(method, parameters);
        if (method.StartsWith("overlay."))
            return await Dispatcher.UIThread.InvokeAsync(() => overlay!.Call(method, parameters, brain!));
        if (method == "host.stateChanged")
        {
            Dispatcher.UIThread.Post(async () =>
            {
                try { if (!stopping) await companion.Refresh(); }
                catch (Exception failure) { Report(failure.Message); }
            });
            return null;
        }
        if (method == "host.saveRule")
        {
            var rule = await brain!.Call("rules.compile", new { input = parameters.GetProperty("input").GetString()! });
            await Dispatcher.UIThread.InvokeAsync(async () =>
            { settings.Rules = [..settings.Rules, rule]; await Configure(); });
            return null;
        }
        if (method == "host.applySetting")
        {
            var change = parameters.GetProperty("setting");
            await Dispatcher.UIThread.InvokeAsync(async () =>
            {
                if (change.TryGetProperty("liveliness", out var level) && level.ValueKind != System.Text.Json.JsonValueKind.Null) settings.Liveliness = level.GetString()!;
                if (change.TryGetProperty("paused", out var paused) && paused.ValueKind != System.Text.Json.JsonValueKind.Null) settings.Paused = paused.GetBoolean();
                if (change.TryGetProperty("persona", out var persona) && persona.ValueKind != System.Text.Json.JsonValueKind.Null) settings.Persona = persona.GetString()!;
                await Configure();
            });
            return null;
        }
        if (method == "host.report")
        {
            await Dispatcher.UIThread.InvokeAsync(() => Report(parameters.GetProperty("error").GetProperty("message").GetString()!));
            return null;
        }
        throw new MissingMethodException(method);
    }

    async Task Configure()
    {
        var snapshot = System.Text.Json.JsonSerializer.Serialize(settings, Protocol.Json);
        chatHotKey?.Configure();
        updater.Configure(settings.AutomaticUpdates && !Program.VerifyUI && !Program.VerifyUpdate && !Program.VerifyUpdateResult);
        UpdateTray();
        if (settings.Paused) overlay?.DismissAll();
        await configurationGate.WaitAsync();
        try
        {
            var configuration = await Task.Run(() =>
            {
                File.WriteAllText(Settings.FilePath, snapshot);
                return System.Text.Json.JsonSerializer.Deserialize<Settings>(snapshot, Protocol.Json)!.Configuration();
            });
            if (brain != null)
            {
                await brain.Call("configure", configuration);
                eventPump ??= Pump(changes!.Reader, brain);
            }
            error = null;
            UpdateTray();
        }
        finally { configurationGate.Release(); }
    }

    async Task<double> TestConnection()
    {
        var reply = await brain!.Call("testConnection", new { generator = await Task.Run(settings.GeneratorConfiguration) });
        return reply.GetProperty("elapsedMilliseconds").GetDouble();
    }

    void ShowSettings()
    {
        if (onboarding != null && !settings.OnboardingCompleted) { onboarding.Activate(); return; }
        if (settingsWindow == null)
        {
            settingsWindow = new SettingsWindow(settings, Configure, TestConnection, updater, () => updater.Install(Quit), companion, suspended =>
            { try { chatHotKey?.Configure(suspended); } catch (Exception failure) { Report(failure.Message); } },
                () => Task.Run(() => global::Windows.Media.Ocr.OcrEngine.AvailableRecognizerLanguages.Where(l => l.LanguageTag.StartsWith("zh-Hans", StringComparison.OrdinalIgnoreCase) || l.LanguageTag is "zh-CN" or "en-US").Select(l => l.DisplayName).ToArray()), Quit);
            settingsWindow.Closed += (_, _) => settingsWindow = null;
        }
        settingsWindow.Refresh(); settingsWindow.Show(); settingsWindow.Activate();
    }

    async void OpenChat(string? narration = null, PixelPoint? near = null)
    {
        try { await ShowChat(narration, near); }
        catch (Exception failure) { Report(failure.Message); }
    }

    async Task ShowChat(string? narration = null, PixelPoint? near = null)
    {
        if (chatWindow == null)
        {
            chatWindow = new ChatWindow(settings, companion);
            chatWindow.Closed += (_, _) => chatWindow = null;
        }
        await chatWindow.Open(narration, near);
    }

    void Report(string message)
    {
        Console.Error.WriteLine(message);
        error = message;
        UpdateTray();
    }

    void UpdateTray()
    {
        identity.Header = companion.Name(settings) + " · Lv." + (companion.Growth?.State.Level ?? 1);
        chatItem.Header = text["chat.open"];
        updateItem.IsVisible = updater.State == UpdateState.Available;
        updateItem.Header = text["updates.available"].Replace("%@", updater.Release?.Tag ?? "");
        updateFailureItem.IsVisible = updateFailure != null;
        updateFailureItem.Header = text["updates.installFailed"] + ": " + updateFailure?.LogPath;
        var paused = settings.Paused;
        status.Header = error == null ? (paused ? text["paused"] : text["sprite.onDuty"]) : text["app.error"];
        tray.ToolTipText = updateFailure != null ? text["updates.installFailed"] + ": " + updateFailure.LogPath
            : error == null ? (string)status.Header! : text["app.error"] + ": " + error.Split('\n')[0];
        tray.Icon = error != null || updateFailure != null ? MakeIcon(225, 55, 75) : paused ? MakeIcon(140, 140, 140) : MakeIcon(42, 166, 100);
        details.IsVisible = error != null;
        var errors = new NativeMenu();
        foreach (var line in error?.Split('\n') ?? []) errors.Items.Add(new NativeMenuItem(line) { IsEnabled = false });
        details.Menu = errors;
        restart.IsEnabled = error != null;
        pause.Header = paused ? text["menu.onDuty"] : text["pause"];
        details.Header = text["error.details"]; restart.Header = text["brain.restart"];
        settingsItem.Header = text["settings"]; quit.Header = text["quit"];
        levelHeader.Header = text["liveliness"]; personaHeader.Header = text["persona"];
        foreach (var (id, item) in levels) item.Header = text["liveliness." + id];
        foreach (var (id, item) in personas) item.Header = Catalog.Personas.Single(p => p.Id == id).Name.Text(settings.EffectiveLanguage);
        foreach (var (id, item) in levels) item.IsChecked = id == settings?.Liveliness;
        foreach (var (id, item) in personas) item.IsChecked = id == settings?.Persona;
    }

    static WindowIcon MakeIcon(byte r, byte g, byte b)
    {
        using var bitmap = new WriteableBitmap(new PixelSize(32, 32), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Unpremul);
        using (var buffer = bitmap.Lock())
        {
            var row = new byte[128];
            for (var y = 0; y < 32; y++)
            {
                Array.Clear(row);
                for (var x = 0; x < 32; x++)
                {
                    if (!((x >= 3 && x < 29 && y >= 4 && y < 24) || (x >= 6 && x < 13 && y >= 24 && y < 29 - (x - 6)))) continue;
                    var dot = y is >= 12 and <= 16 && (x is >= 8 and <= 10 or >= 15 and <= 17 or >= 22 and <= 24);
                    row[x * 4] = dot ? (byte)255 : b; row[x * 4 + 1] = dot ? (byte)255 : g;
                    row[x * 4 + 2] = dot ? (byte)255 : r; row[x * 4 + 3] = 255;
                }
                Marshal.Copy(row, 0, buffer.Address + y * buffer.RowBytes, row.Length);
            }
        }
        using var png = new MemoryStream();
        bitmap.Save(png); png.Position = 0;
        return new WindowIcon(png);
    }

    async Task Stop()
    {
        stopping = true;
        chatWindow?.Close(); chatWindow = null;
        chatHotKey?.Dispose(); chatHotKey = null;
        events?.Dispose(); events = null;
        changes?.Writer.TryComplete();
        if (brain != null) { await brain.DisposeAsync(); brain = null; }
        if (eventPump != null) { await eventPump; eventPump = null; }
        sensor?.Dispose(); sensor = null;
        overlay?.Dispose(); overlay = null;
    }

    async Task Quit()
    {
        exiting = true;
        await Stop();
        updater.Dispose(); tray.Dispose(); desktop.Shutdown();
    }
}
