using System.Threading.Channels;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Threading;

namespace LifeNarrator.Windows;

public sealed partial class ShellApp : Application
{
    IClassicDesktopStyleApplicationLifetime desktop = null!;
    Settings settings = null!;
    WindowsTray tray = null!;
    TrayMenuWindow? trayMenu;
    RuleInputWindow? ruleInput;
    bool ocrUnavailable;
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
    OnboardingWindow? onboarding;
    AnnouncementPresenter announcements = null!;
    readonly SemaphoreSlim configurationGate = new(1);
    Texts text = null!;
    Updater updater = null!;
    UpdateFailure? updateFailure;
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
        announcements = new AnnouncementPresenter(settings, settings.Save, Report);
        companion = new Companion((method, parameters) => brain!.Call(method, parameters));
        companion.Changed += UpdateTray;
        updater = new Updater(Program.VerifyUpdate ? new Uri(Environment.GetEnvironmentVariable("LIFENARRATOR_UPDATE_RELEASES")!) : null);
        updater.Changed += UpdateTray;
        tray = new WindowsTray(ShowTray);
        var show = new EventWaitHandle(false, EventResetMode.AutoReset, Program.ShowSettingsEvent);
        new Thread(() => { while (show.WaitOne()) Dispatcher.UIThread.Post(ShowSettings); }) { IsBackground = true }.Start();
        Dispatcher.UIThread.Post(async () =>
        {
            try
            {
                await Task.Run(() => { Startup.SetEnabled(settings.LaunchAtLogin); _ = settings.Downloaders; updateFailure = updater.PreviousFailure(); });
                await Start();
                updater.Configure(settings.AutomaticUpdates && !Program.VerifyUI && !Program.VerifyUpdate && !Program.VerifyUpdateResult);
                if (!settings.OnboardingCompleted)
                {
                    onboarding = new OnboardingWindow(settings, Configure, TestConnection, ShowSettings, OcrLanguages);
                    onboarding.Closed += (_, _) => { onboarding = null; announcements.ShowIfNeeded(); };
                    onboarding.Show();
                }
                else announcements.ShowIfNeeded();
                if (Program.VerifyUI) await VerifyUI();
                if (Program.VerifyCompanion) await VerifyCompanion();
                if (Program.VerifyUpdate) await VerifyUpdate();
                if (Program.VerifyUpdateResult) await VerifyUpdateResult();
            }
            catch (Exception failure) { Report(failure.Message); if (Program.VerifyUI || Program.VerifyCompanion) desktop.Shutdown(1); }
        });
        base.OnFrameworkInitializationCompleted();
    }

    Task<string[]> OcrLanguages() => Task.Run(() => global::Windows.Media.Ocr.OcrEngine.AvailableRecognizerLanguages
        .Where(l => l.LanguageTag.StartsWith("zh-Hans", StringComparison.OrdinalIgnoreCase) || l.LanguageTag is "zh-CN" or "en-US")
        .Select(l => l.DisplayName).ToArray());

    void ShowTray(PixelPoint point)
    {
        trayMenu ??= new TrayMenuWindow(settings, companion, async () => { await Configure(); settingsWindow?.Refresh(); }, () => ShowChat(), () => { ShowInput(); return Task.CompletedTask; },
            tab => { ShowSettings(); settingsWindow?.SelectTab(tab); }, Quit, updater, async () => { await Stop(); await Start(); });
        trayMenu.Refresh(error, ocrUnavailable, updateFailure); trayMenu.Open(point);
    }

    void ShowInput()
    {
        ruleInput ??= new RuleInputWindow(settings, companion, Configure);
        ruleInput.Open();
    }

    async Task Start()
    {
        stopping = false;
        error = null;
        UpdateTray();
        overlay = new OverlayController(settings, Report, companion, (narration, point) => OpenChat(narration, point));
        chatHotKey = new ChatHotKey(settings, async () =>
        { try { settings.Paused = !settings.Paused; await Configure(); settingsWindow?.Refresh(); } catch (Exception failure) { Report(failure.Message); } },
            () => OpenChat(), ShowInput);
        var channel = Channel.CreateUnbounded<(string, object)>(new UnboundedChannelOptions { SingleReader = true });
        changes = channel;
        var input = new WindowEvents(() => sensor?.RequestRead(),
            wheel => Dispatcher.UIThread.Post(() => overlay?.Scrolled(wheel)));
        events = input;
        sensor = new ContextSensor(overlay.Displays,
            (method, p) => channel.Writer.TryWrite((method, p)),
            message => Dispatcher.UIThread.Post(() => Report(message)), () => input.LastTypedAt, () => input.ScrollAt,
            () => Dispatcher.UIThread.Post(() => overlay?.Scrolled(true)),
            unavailable => Dispatcher.UIThread.Post(() => { ocrUnavailable = unavailable; UpdateTray(); }));
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
            settingsWindow = new SettingsWindow(settings, Program.VerifyUI ? ConfigureForVerification : Configure, TestConnection, updater, () => updater.Install(Quit), companion, suspended =>
            { try { chatHotKey?.Configure(suspended); } catch (Exception failure) { Report(failure.Message); } },
                OcrLanguages, Quit, announcements.Show);
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
        var status = settings.Paused ? text["paused"] : text["sprite.onDuty"];
        var failure = error ?? (updater.State == UpdateState.Failed ? updater.Error : null);
        var tip = updateFailure != null ? text["updates.installFailed"] + ": " + updateFailure.LogPath
            : failure == null ? status : text["app.error"] + ": " + failure.Split('\n')[0];
        tray.Update(tip, settings.Paused, failure != null || updateFailure != null);
        trayMenu?.Refresh(error, ocrUnavailable, updateFailure);
    }

    async Task Stop()
    {
        stopping = true;
        chatWindow?.Close(); chatWindow = null;
        ruleInput?.Close(); ruleInput = null;
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
