using System.Text.Json;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Media.Imaging;
using Avalonia.Interactivity;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class RestChecks
{
    static void Wait(Task task)
    {
        task = task.WaitAsync(TimeSpan.FromSeconds(20));
        var frame = new DispatcherFrame();
        task.ContinueWith(_ => Dispatcher.UIThread.Post(() => frame.Continue = false));
        Dispatcher.UIThread.PushFrame(frame); task.GetAwaiter().GetResult();
    }
    static void Capture(Window window, string path)
    {
        Dispatcher.UIThread.RunJobs(); window.UpdateLayout();
        using var frame = new RenderTargetBitmap(PixelSize.FromSize(window.ClientSize, window.RenderScaling), new Vector(96, 96) * window.RenderScaling);
        frame.Render(window);
        frame.Save(path);
    }
    static T Find<T>(Window window, string id) where T : Control
    { Dispatcher.UIThread.RunJobs(); window.UpdateLayout(); return window.GetVisualDescendants().OfType<T>().Single(c => AutomationProperties.GetAutomationId(c) == id); }
    static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    public static void Run()
    {
        foreach (var language in new[] { "zh", "en" })
        foreach (var theme in new[] { "light", "dark" })
        {
            Application.Current!.RequestedThemeVariant = theme == "light" ? ThemeVariant.Light : ThemeVariant.Dark;
            var directory = $"artifacts/rest/{language}/{theme}"; Directory.CreateDirectory(directory);
            var settings = new Settings { Language = language, Liveliness = "quiet", Provider = new ProviderSettings { Kind = "builtin" } };
            using var updater = new Updater();
            var modelDirectory = Path.GetFullPath("artifacts/rest/partial-fixture"); Directory.CreateDirectory(modelDirectory);
            var models = Catalog.Models.Select(m => m with { Size = 1000 }).ToArray();
            var partialPath = Path.Combine(modelDirectory, models[0].Filename) + ".download";
            File.WriteAllBytes(partialPath, new byte[989]);
            var downloads = models.Select(m => new ModelDownloader(m, modelDirectory)).ToArray();
            var pausedSettings = new Settings(downloads) { Language = language, Provider = new ProviderSettings { Kind = "builtin" } };
            var pausedModel = new Window { Width = 780, Height = 580, Content = new ModelView(pausedSettings, () => Task.CompletedTask, () => Task.FromResult(1d)), FontFamily = Views.Font(settings) };
            pausedModel.Show(); pausedModel.UpdateLayout();
            if (!pausedModel.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == (language == "zh" ? "已暂停 99%" : "Paused 99%")))
                throw new Exception("Interrupted 98.9% model did not show paused 99%");
            Capture(pausedModel, $"{directory}/ui-model-paused-{theme}.png"); pausedModel.Close(); File.Delete(partialPath);
            var wizard = new OnboardingWindow(settings, () => Task.CompletedTask, () => Task.FromResult(1d), () => { },
                () => Task.FromResult(new[] { "简体中文", "English (United States)" }));
            wizard.Show();
            for (var step = 1; step <= 3; step++)
            {
                Capture(wizard, $"{directory}/ui-onboarding-{step}-{theme}.png"); Wait(wizard.Advance());
            }
            if (!settings.OnboardingCompleted) throw new Exception("Onboarding did not save completion");
            settings.Provider.Kind = "none";
            foreach (var level in new[] { 1, 15 })
            {
                settings.BubbleShape = level == 1 ? "text" : "star"; settings.BubbleTheme = level == 1 ? "clear" : "starry";
                var growth = new GrowthInfo(new GrowthNumbers(level, level == 1 ? 30 : 9230, 30, 7, 1420, 86, 3,
                    level == 1 ? [] : ["spriteName", "starBubble", "starryTheme"]), language == "zh" ? "星仔" : "Stella", "", level == 1 ? 160 : 10240, 30, []);
                var turns = new[] { new ChatTurn("rest-fixture", language == "zh" ? "你记得我什么" : "What do you remember?",
                    level == 1 ? (language == "zh" ? "还没记住你的事，聊聊吧。" : "Tell me a little about yourself.")
                        : (language == "zh" ? "你喜欢茉莉花茶，我记着呢。" : "You enjoy jasmine tea. I remember."), null) };
                var companion = new Companion((method, _) => Task.FromResult(JsonSerializer.SerializeToElement(method switch
                {
                    "growth.state" => (object)growth, "memory.list" => Array.Empty<MemoryEntry>(), "chat.history" => turns,
                    _ => throw new MissingMethodException(method)
                }, Protocol.Json)));
                Wait(companion.Refresh());
                var chat = new ChatWindow(settings, companion); Wait(chat.Open());
                Capture(chat, $"{directory}/ui-chat-lv{level}-{language}-{theme}.png");
                if (!chat.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == "Lv." + level)) throw new Exception("Missing chat level");
                if (chat.GetVisualDescendants().OfType<BubbleVisual>().Single().Style.Shape != settings.BubbleShape) throw new Exception("Chat ignored bubble shape");
                chat.Close();
                var opened = ""; var selectedTab = -1;
                Task Action(string name) { opened = name; return Task.CompletedTask; }
                var menu = new TrayMenuWindow(settings, companion, () => Task.CompletedTask, () => Action("chat"), () => Action("input"),
                    tab => selectedTab = tab, () => Action("quit"), updater, () => Action("restart"));
                menu.Open(new PixelPoint(700, 700));
                Capture(menu, $"{directory}/ui-menu-lv{level}-{language}-{theme}.png");
                Click(Find<Button>(menu, "tray-input.open"));
                if (opened != "input" || menu.IsVisible) throw new Exception("Tray input action did not dismiss/open");
                menu.Open(new PixelPoint(700, 700)); Click(Find<Button>(menu, "tray-settings"));
                if (selectedTab != SettingsWindow.SpriteTab) throw new Exception("Tray settings entry missing");
                menu.Open(new PixelPoint(700, 700));
                var duty = Find<ToggleButton>(menu, "tray-duty"); duty.IsChecked = false; Click(duty);
                if (!settings.Paused) throw new Exception("Tray duty switch did not pause");
                if (level == 1) Capture(menu, $"{directory}/ui-menu-paused-{theme}.png");
                settings.Paused = false; menu.Refresh(language == "zh" ? "大脑连接失败" : "Brain connection failed", true, null);
                menu.Open(new PixelPoint(700, 700)); Click(Find<Button>(menu, "tray-details"));
                Capture(menu, $"{directory}/ui-menu-details-lv{level}-{theme}.png");
                if (menu.GetVisualDescendants().OfType<ComboBox>().Count() != 2 || !menu.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == new Texts(settings)["ocr.unavailable"]))
                    throw new Exception("Tray lost persona/liveliness/OCR details");
                menu.Close();
            }
            var pending = new TaskCompletionSource<JsonElement>(); var calls = 0; var configurations = 0;
            var rule = JsonSerializer.SerializeToElement(new { id = "rest.rule", enabled = true, kind = "person", input = "张三是我领导",
                label = new { zh = "张三是我领导", en = "Zhang is my manager" } }, Protocol.Json);
            var ruleCompanion = new Companion((method, _) => method switch
            {
                "rules.compile" => Compile(), "growth.state" => Task.FromResult(JsonSerializer.SerializeToElement(new GrowthInfo(new GrowthNumbers(1, 30, 1, 1, 0, 0, 1, []), "", "", 160, 1, []), Protocol.Json)),
                "memory.list" => Task.FromResult(JsonSerializer.SerializeToElement(Array.Empty<MemoryEntry>(), Protocol.Json)),
                _ => throw new MissingMethodException(method)
            });
            Task<JsonElement> Compile() { calls++; return pending.Task; }
            var panel = new RuleInputWindow(settings, ruleCompanion, () => { configurations++; return Task.CompletedTask; }); panel.Open();
            Capture(panel, $"{directory}/ui-input-idle-{theme}.png");
            var input = Find<TextBox>(panel, "rule-panel-input"); input.Text = language == "zh" ? "张三是我领导" : "Zhang is my manager";
            input.Focus(); panel.KeyPressQwerty(PhysicalKey.Enter, RawInputModifiers.None); panel.KeyReleaseQwerty(PhysicalKey.Enter, RawInputModifiers.None);
            if (calls != 1 || input.IsEnabled) throw new Exception("Rule Enter did not compile");
            Wait(panel.Compile());
            Capture(panel, $"{directory}/ui-input-compiling-{theme}.png");
            var outside = new Window(); outside.Show(); outside.Activate(); Dispatcher.UIThread.RunJobs();
            if (!panel.IsVisible) throw new Exception("Compiling panel hid before result"); outside.Close();
            var responsive = false; Dispatcher.UIThread.Post(() => responsive = true); Dispatcher.UIThread.RunJobs();
            if (!responsive) throw new Exception("Compiling blocked UI");
            pending.SetResult(rule); Dispatcher.UIThread.RunJobs();
            if (settings.Rules.Length != 1 || configurations != 1 || !input.IsEnabled) throw new Exception("Compiled rule was not saved");
            Capture(panel, $"{directory}/ui-input-saved-{theme}.png");
            pending = new TaskCompletionSource<JsonElement>(); input.Text = "error"; var failed = panel.Compile();
            pending.SetException(new IOException(language == "zh" ? "无法创建规则：服务连接失败。" : "Could not create rule: connection failed.")); Wait(failed);
            Capture(panel, $"{directory}/ui-input-error-{theme}.png");
            if (settings.Rules.Length != 1) throw new Exception("Failed rule changed saved rules");
            panel.Close();
        }
        Console.WriteLine("PASS: onboarding/OCR; chat lv1/lv15 and appearance; tray actions/duty/details; rule Enter/compiling/saved/error and responsive UI; Chinese/English light/dark snapshots in artifacts/rest");
    }
}
