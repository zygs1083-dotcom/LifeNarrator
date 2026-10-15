using System.Runtime.InteropServices;
using System.Threading.Channels;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;

namespace LifeNarrator.Windows;

public sealed class ShellApp : Application
{
    IClassicDesktopStyleApplicationLifetime desktop = null!;
    Settings settings = null!;
    TrayIcon tray = null!;
    NativeMenuItem status = null!, pause = null!, restart = null!, details = null!;
    readonly Dictionary<string, NativeMenuItem> levels = new(), personas = new();
    BrainClient? brain;
    ContextSensor? sensor;
    WindowEvents? events;
    OverlayController? overlay;
    Channel<(string Method, object Params)>? changes;
    Task? eventPump;
    bool exiting;
    bool stopping;
    string? error;

    public override void OnFrameworkInitializationCompleted()
    {
        desktop = (IClassicDesktopStyleApplicationLifetime)ApplicationLifetime!;
        desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        status = new NativeMenuItem { Header = "人生旁白", IsEnabled = false };
        details = new NativeMenuItem { Header = "", IsVisible = false, IsEnabled = false };
        pause = Item("在岗", async () => { settings.Paused = !settings.Paused; await Configure(); });
        var levelMenu = new NativeMenu();
        foreach (var (id, label) in new[] { ("quiet", "安静"), ("lively", "热闹"), ("rowdy", "吵闹") })
        {
            var item = Item(label, async () => { settings.Liveliness = id; await Configure(); });
            item.ToggleType = NativeMenuItemToggleType.Radio;
            levels.Add(id, item); levelMenu.Items.Add(item);
        }
        var personaMenu = new NativeMenu();
        foreach (var (id, label) in new[] { ("sharp", "毒舌"), ("gentle", "温柔"), ("chuuni", "中二"),
            ("teacher", "老师"), ("mom", "妈妈"), ("hype", "捧场"), ("cat", "猫咪") })
        {
            var item = Item(label, async () => { settings.Persona = id; await Configure(); });
            item.ToggleType = NativeMenuItemToggleType.Radio;
            personas.Add(id, item); personaMenu.Items.Add(item);
        }
        restart = Item("重启大脑", async () => { await Stop(); await Start(); });
        var menu = new NativeMenu();
        menu.Items.Add(status); menu.Items.Add(details); menu.Items.Add(pause);
        menu.Items.Add(new NativeMenuItem("热闹程度") { Menu = levelMenu });
        menu.Items.Add(new NativeMenuItem("人格") { Menu = personaMenu });
        menu.Items.Add(restart); menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(Item("退出", async () => { exiting = true; await Stop(); tray.Dispose(); desktop.Shutdown(); }));
        tray = new TrayIcon { Menu = menu, ToolTipText = "人生旁白", Icon = MakeIcon(42, 166, 100), IsVisible = true };
        TrayIcon.SetIcons(this, new TrayIcons { tray });
        Dispatcher.UIThread.Post(async () =>
        {
            try { settings = Settings.Load(); await Start(); }
            catch (Exception failure) { Report(failure.Message); }
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
        settings ??= Settings.Load();
        error = null;
        UpdateTray();
        overlay = new OverlayController(settings);
        var channel = Channel.CreateUnbounded<(string, object)>(new UnboundedChannelOptions { SingleReader = true });
        changes = channel;
        var input = new WindowEvents(() => sensor?.RequestRead());
        events = input;
        sensor = new ContextSensor(overlay.Displays,
            (method, p) => channel.Writer.TryWrite((method, p)),
            message => Dispatcher.UIThread.Post(() => Report(message)), () => input.LastTypedAt, () => input.ScrollAt);
        brain = new BrainClient(Path.Combine(AppContext.BaseDirectory, "brain", "narrator-brain.exe"),
            Path.Combine(Settings.DataDirectory, "brain.log"), Port,
            message => Dispatcher.UIThread.Post(() => { overlay?.DismissAll(); Report(message); }));
        await brain.Call("configure", settings.Configuration());
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
        if (method == "host.report")
        {
            await Dispatcher.UIThread.InvokeAsync(() => Report(parameters.GetProperty("error").GetProperty("message").GetString()!));
            return null;
        }
        throw new MissingMethodException(method);
    }

    async Task Configure()
    {
        settings.Save();
        UpdateTray();
        if (settings.Paused) overlay?.DismissAll();
        if (brain != null) await brain.Call("configure", settings.Configuration());
    }

    void Report(string message)
    {
        Console.Error.WriteLine(message);
        error = message;
        UpdateTray();
    }

    void UpdateTray()
    {
        var paused = settings?.Paused == true;
        status.Header = error == null ? (paused ? "已暂停" : "小精灵在岗") : "人生旁白出错";
        tray.ToolTipText = error == null ? (string)status.Header! : "人生旁白出错：" + error.Split('\n')[0];
        tray.Icon = error != null ? MakeIcon(225, 55, 75) : paused ? MakeIcon(140, 140, 140) : MakeIcon(42, 166, 100);
        details.Header = error ?? ""; details.IsVisible = error != null;
        restart.IsEnabled = error != null;
        pause.Header = paused ? "在岗" : "暂停";
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
        events?.Dispose(); events = null;
        changes?.Writer.TryComplete();
        if (brain != null) { await brain.DisposeAsync(); brain = null; }
        if (eventPump != null) { await eventPump; eventPump = null; }
        sensor?.Dispose(); sensor = null;
        overlay?.Dispose(); overlay = null;
    }
}
