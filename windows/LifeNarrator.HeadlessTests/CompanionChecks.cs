using System.Text.Json;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Styling;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class CompanionChecks
{
    public static void Run()
    {
        var settings = new Settings { Language = "zh", BubbleShape = "star", BubbleTheme = "starry", Emoji = "🌈" };
        var unlocked = new[] { "spriteName", "emoji", "starBubble", "catchphrase", "greetings", "starryTheme" };
        var numbers = new GrowthNumbers(15, 9100, 30, 7, 250, 28, 3, unlocked);
        var growth = new GrowthInfo(numbers, "小星", "吐槽学徒", 10240, 30,
            [new("spriteName", 2, "名字"), new("emoji", 3, "更多表情"), new("starBubble", 5, "星星气泡"),
             new("starryTheme", 15, "星空主题"), new("oldFriend", 20, "老朋友人格")]);
        var entries = new[] { new MemoryEntry("fixture", "preference", "喜欢喝抹茶", "chat", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, 1, true) };
        var calls = new List<(string Method, JsonElement Params)>();
        var companion = new Companion((method, parameters) =>
        {
            var p = JsonSerializer.SerializeToElement(parameters, Protocol.Json); calls.Add((method, p));
            object? reply = method switch
            {
                "growth.state" => growth, "memory.list" => entries,
                "chat.history" => new[] { new ChatTurn("earlier", "今天有点累", "慢慢来，我陪着你。", null) },
                "chat.send" => new ChatTurn("sent", p.GetProperty("text").GetString()!, "记住啦。", "随时可以在设置里查看或删除记忆。"),
                "memory.pin" or "growth.setName" => null,
                _ => throw new MissingMethodException(method)
            };
            return Task.FromResult(JsonSerializer.SerializeToElement(reply, Protocol.Json));
        });
        companion.Refresh().GetAwaiter().GetResult();
        if (companion.Name(settings) != "小星" || settings.ActiveShape(growth) != "star" || settings.ActiveTheme(growth) != "starry"
            || !settings.ActiveEmoji(["😺"], growth).SequenceEqual(["🌈"])) throw new Exception("Unlocked preferences not applied");
        var locked = growth with { State = numbers with { Level = 1, Unlocked = [] } };
        if (settings.ActiveShape(locked) != "automatic" || settings.ActiveTheme(locked) != "random" || settings.ActiveEmoji(["😺"], locked)[0] != "😺")
            throw new Exception("Locked appearance leaked into overlay");
        using var updater = new Updater();
        var window = new SettingsWindow(settings, () => Task.CompletedTask, () => Task.FromResult(1d), updater, () => Task.CompletedTask, companion);
        window.Show();
        foreach (var variant in new[] { ThemeVariant.Light, ThemeVariant.Dark })
        {
            Application.Current!.RequestedThemeVariant = variant;
            window.SelectTab(0); Capture(window, "growth-" + variant);
            window.SelectTab(SettingsWindow.MemoryTab); Capture(window, "memory-" + variant);
        }
        var pin = window.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == new Texts(settings)["memory.unpin"]);
        pin.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (!calls.Any(c => c.Method == "memory.pin" && !c.Params.GetProperty("pinned").GetBoolean())) throw new Exception("Pin action did not call brain");
        growth = locked; companion.Refresh().GetAwaiter().GetResult(); window.SelectTab(0); window.UpdateLayout();
        var name = window.GetVisualDescendants().OfType<TextBox>().Single(b => AutomationProperties.GetAutomationId(b) == "sprite-name");
        if (name.IsEnabled) throw new Exception("Locked controls enabled");
        growth = growth with { State = numbers }; companion.Refresh().GetAwaiter().GetResult();
        window.Close();
        var chat = new ChatWindow(settings, companion);
        chat.Open("有我陪你呀").GetAwaiter().GetResult(); chat.UpdateLayout();
        var input = chat.GetVisualDescendants().OfType<TextBox>().Single();
        input.Focus(); chat.KeyTextInput("请记住我喜欢抹茶");
        chat.GetVisualDescendants().OfType<ToggleButton>().Single(b => AutomationProperties.GetAutomationId(b) == "chat-screen").IsChecked = true;
        chat.KeyPressQwerty(PhysicalKey.Enter, RawInputModifiers.None); chat.KeyReleaseQwerty(PhysicalKey.Enter, RawInputModifiers.None);
        if (!calls.Any(c => c.Method == "chat.send" && c.Params.GetProperty("includeScreen").GetBoolean()
            && c.Params.GetProperty("narration").GetString() == "有我陪你呀") || input.Text != "") throw new Exception("Chat Enter send did not preserve context/checkbox");
        Capture(chat, "chat"); chat.Close();
        var starry = new BubbleVisual("star", "辛苦啦，慢慢来", ["🌈"], "zh", "medium", true, false, shape: "star", theme: "starry");
        var bubble = new Window { Width = starry.Width, Height = starry.Height, Content = starry };
        bubble.Show(); Capture(bubble, "star-bubble"); bubble.Close();
        Console.WriteLine("PASS: chat Enter send/context/screen checkbox; memory pin RPC; locked controls; growth, memory, chat and starry star screenshots");
    }

    static void Capture(Window window, string name)
    {
        using var frame = window.CaptureRenderedFrame() ?? throw new Exception("No companion pixels");
        frame.Save("artifacts/ui-headless-" + name + ".png");
    }
}
