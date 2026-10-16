using System.Text.Json;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class SettingsInteractionChecks
{
    static IEnumerable<T> Find<T>(Window window) where T : Control => window.GetVisualDescendants().OfType<T>();
    static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    public static void Run()
    {
        var settings = new Settings { Language = "en", Provider = new ProviderSettings { Kind = "api", Model = "fixture" } };
        var pending = new TaskCompletionSource();
        var companion = new Companion((method, p) =>
        {
            var reply = method switch
            {
                "growth.state" => (object)new GrowthInfo(new GrowthNumbers(1, 0, 0, 0, 0, 0, 0, []), "", "Just hatched", 160, 0, [new("spriteName", 2, "Name")]),
                "memory.list" => Array.Empty<MemoryEntry>(),
                "chat.history" => new[] { new ChatTurn("custom-chat", "Hello", "Hi there", null) },
                "rules.compile" => JsonSerializer.SerializeToElement(new { id = "own.fixture", kind = "topic", enabled = true, label = new { zh = "开会", en = "Meetings" }, input = "Meetings" }),
                "personas.generate" => JsonSerializer.SerializeToElement(new { id = "custom.fixture", emoji = "😺", pack = "gentle", name = new { zh = "伙伴", en = "Buddy" }, caption = new { zh = "朋友", en = "Friend" } }),
                _ => throw new MissingMethodException(method)
            };
            return Task.FromResult(JsonSerializer.SerializeToElement(reply, Protocol.Json));
        });
        companion.Refresh().GetAwaiter().GetResult();
        using var updater = new Updater();
        var window = new SettingsWindow(settings, () => pending.Task, () => Task.FromResult(1d), updater, () => Task.CompletedTask, companion);
        window.Show(); window.SelectTab(SettingsWindow.GeneralTab); window.UpdateLayout();
        var recorder = Find<Button>(window).Single(b => AutomationProperties.GetName(b) == new Texts(settings)["shortcut.pause"]);
        recorder.Focus(); Click(recorder);
        window.KeyPressQwerty(PhysicalKey.K, RawInputModifiers.Control | RawInputModifiers.Alt);
        window.KeyReleaseQwerty(PhysicalKey.K, RawInputModifiers.Control | RawInputModifiers.Alt);
        if (settings.PauseShortcut != new HotKey(3, 0x4B)) throw new Exception("Shortcut recorder did not capture Ctrl+Alt+K");
        window.SelectTab(SettingsWindow.SpriteTab); window.UpdateLayout();
        var slider = Find<Slider>(window).Single(s => AutomationProperties.GetAutomationId(s) == "pace.gap"); slider.Value = 11;
        window.SelectTab(SettingsWindow.RulesTab); window.UpdateLayout();
        if (settings.MarkGap != 11 || Find<ToggleButton>(window).Count(b => AutomationProperties.GetAutomationId(b)?.StartsWith("tab-") == true) != 6)
            throw new Exception("Settings stopped responding while configuration was pending");
        var all = Find<ToggleButton>(window).Single(b => AutomationProperties.GetAutomationId(b) == "builtin-enabled");
        all.IsChecked = false; Click(all);
        settings.Provider.Kind = "none";
        var config = JsonSerializer.SerializeToElement(settings.Configuration(), Protocol.Json);
        if (config.GetProperty("settings").GetProperty("disabledBuiltinIds").GetArrayLength() != Catalog.BuiltinRules.Length)
            throw new Exception("Builtin pack toggle did not reach brain configuration");
        pending.SetResult(); Dispatcher.UIThread.RunJobs();
        window.SelectTab(SettingsWindow.RulesTab); window.UpdateLayout();
        Click(Find<Button>(window).Single(b => AutomationProperties.GetAutomationId(b) == "rule-add"));
        var editor = window.OwnedWindows.Single(); editor.UpdateLayout();
        var ruleInput = Find<TextBox>(editor).Single(); ruleInput.Text = "Meetings";
        Click(Find<Button>(editor).Single(b => b.Content as string == "Save")); Dispatcher.UIThread.RunJobs();
        if (settings.Rules.Length != 1) throw new Exception("Rule editor did not compile/save through brain");
        window.UpdateLayout();
        var own = Find<ToggleButton>(window).Single(b => AutomationProperties.GetAutomationId(b) == "rule-enabled-own.fixture");
        own.IsChecked = false; Click(own);
        if (settings.Rules[0].GetProperty("enabled").GetBoolean()) throw new Exception("Own rule toggle did not persist");
        Click(Find<Button>(window).Single(b => AutomationProperties.GetName(b) == "Delete"));
        if (settings.Rules.Length != 0) throw new Exception("Own rule delete did not persist");
        settings.Provider = new ProviderSettings { Kind = "api", Model = "fixture" };
        window.SelectTab(SettingsWindow.SpriteTab); window.UpdateLayout();
        Click(Find<Button>(window).Single(b => AutomationProperties.GetAutomationId(b) == "persona-add"));
        var personaEditor = window.OwnedWindows.Single(); personaEditor.UpdateLayout();
        Find<TextBox>(personaEditor).Single().Text = "A friendly buddy";
        Click(Find<Button>(personaEditor).Single(b => b.Content as string == "Create persona")); Dispatcher.UIThread.RunJobs();
        if (settings.Persona != "custom.fixture" || settings.CustomPersonas.Length != 1) throw new Exception("Custom persona generation did not persist/select");
        window.SelectTab(SettingsWindow.AppearanceTab); window.UpdateLayout();
        var shape = Find<ComboBox>(window).Single(b => AutomationProperties.GetAutomationId(b) == "appearance-shape");
        if (shape.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag! == "star").IsEnabled) throw new Exception("Locked star shape is selectable");
        Click(Find<ToggleButton>(window).Single(b => AutomationProperties.GetAutomationId(b) == "appearance-size-large"));
        var preview = Find<BubblePreview>(window).Single();
        if (settings.BubbleSize != "large" || preview.Style.Size != "large" || preview.Persona != "gentle")
            throw new Exception("Appearance controls did not update preview or resolve custom persona font");
        window.Close();
        var customChat = new ChatWindow(settings, companion); customChat.Open().GetAwaiter().GetResult(); customChat.UpdateLayout();
        if (Find<BubbleVisual>(customChat).Count() != 1) throw new Exception("Custom persona could not render chat history");
        customChat.Close();
        if (HotKey.FromKey(Key.LeftAlt, KeyModifiers.Alt) != null || HotKey.FromKey(Key.K, KeyModifiers.None) != null)
            throw new Exception("Shortcut accepted bare modifier or unmodified typing key");
        Console.WriteLine("PASS: shortcut recording; all six tabs and edits respond while brain configuration is pending; builtin pack persistence");
    }
}
