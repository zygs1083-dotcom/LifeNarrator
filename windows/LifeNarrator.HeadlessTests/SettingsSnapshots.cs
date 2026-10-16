using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class SettingsSnapshots
{
    internal static Companion Companion(Settings settings, bool filled = false)
    {
        var companion = new Companion((method, _) => Task.FromResult(JsonSerializer.SerializeToElement(method switch
        {
            "growth.state" => (object)new GrowthInfo(new GrowthNumbers(1, 0, 0, 0, 0, 0, 0, []), "", settings.EffectiveLanguage == "zh" ? "刚孵出来" : "Just hatched", 160, 0,
                [new("spriteName", 2, settings.EffectiveLanguage == "zh" ? "给小精灵起名字" : "Name your sprite"), new("emoji", 3, "Emoji")]),
            "memory.list" => filled ? new[] { new MemoryEntry("fixture", "preference", settings.EffectiveLanguage == "zh" ? "喜欢喝抹茶" : "Likes matcha", "chat", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, 1, true) } : Array.Empty<MemoryEntry>(), _ => throw new MissingMethodException(method)
        }, Protocol.Json)));
        companion.Refresh().GetAwaiter().GetResult(); return companion;
    }
    public static void Run()
    {
        var names = new[] { "sprite", "appearance", "tab.memory", "rules", "models", "general" };
        foreach (var language in new[] { "zh", "en" })
        foreach (var theme in new[] { "light", "dark" })
        {
            Application.Current!.RequestedThemeVariant = theme == "light" ? ThemeVariant.Light : ThemeVariant.Dark;
            var settings = new Settings { Language = language, Provider = new ProviderSettings { Kind = "builtin" } };
            using var updater = new Updater();
            var companion = Companion(settings);
            var window = new SettingsWindow(settings, () => Task.CompletedTask, () => Task.FromResult(1d), updater, () => Task.CompletedTask,
                companion, ocrLanguages: () => Task.FromResult(new[] { "简体中文", "English (United States)" }));
            window.Show();
            var directory = $"artifacts/settings/{language}/{theme}"; Directory.CreateDirectory(directory);
            for (var tab = 0; tab < names.Length; tab++)
            {
                window.SelectTab(tab); Dispatcher.UIThread.RunJobs(); window.UpdateLayout();
                using (var frame = window.CaptureRenderedFrame() ?? throw new Exception("No settings pixels"))
                    frame.Save($"{directory}/ui-settings-{names[tab]}-{theme}.png");
                var scroll = window.GetVisualDescendants().OfType<ScrollViewer>().Single(s => s.Name == "settings-scroll");
                scroll.ScrollToEnd(); Dispatcher.UIThread.RunJobs(); window.UpdateLayout();
                using var scrolled = window.CaptureRenderedFrame() ?? throw new Exception("No scrolled settings pixels");
                scrolled.Save($"{directory}/ui-settings-{names[tab]}-scrolled-{theme}.png");
            }
            window.Close();
            settings.Rules = new[] { ("person", "张三是我领导", "Zhang is my manager"), ("site", "我讨厌谷歌", "I dislike Google"), ("topic", "我讨厌开会", "I dislike meetings") }
                .Select((r, i) => JsonSerializer.SerializeToElement(new { id = "fixture-" + i, kind = r.Item1, enabled = true, input = language == "zh" ? r.Item2 : r.Item3,
                    label = new { zh = r.Item2, en = r.Item3 } }, Protocol.Json)).ToArray();
            var filled = new SettingsWindow(settings, () => Task.CompletedTask, () => Task.FromResult(1d), updater, () => Task.CompletedTask, Companion(settings, filled: true));
            filled.Show();
            foreach (var (index, name) in new[] { (SettingsWindow.RulesTab, "rules"), (SettingsWindow.MemoryTab, "memory") })
            {
                filled.SelectTab(index); Dispatcher.UIThread.RunJobs(); filled.UpdateLayout();
                using var frame = filled.CaptureRenderedFrame() ?? throw new Exception("No filled settings pixels"); frame.Save($"{directory}/ui-{name}-filled-{theme}.png");
            }
            filled.Close();
            using var comparison = new RenderTargetBitmap(new PixelSize(780, 6 * 310), new Vector(96, 96));
            var panel = new StackPanel();
            for (var tab = 0; tab < names.Length; tab++)
            {
                var mac = $"windows/LifeNarrator.HeadlessTests/MacReference/ui-settings-{names[tab]}-{theme}.png";
                var row = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal };
                row.Children.Add(new Image { Source = new Bitmap(mac), Width = 390, Height = 290 });
                row.Children.Add(new Image { Source = new Bitmap($"{directory}/ui-settings-{names[tab]}-{theme}.png"), Width = 390, Height = 290 });
                panel.Children.Add(new TextBlock { Text = names[tab] + " · Mac (zh) / Windows (" + language + ")", Height = 20, Foreground = Brushes.Black });
                panel.Children.Add(row);
            }
            var canvas = new Border { Background = Brushes.White, Child = panel };
            canvas.Measure(new Size(780, 1860)); canvas.Arrange(new Rect(0, 0, 780, 1860)); comparison.Render(canvas);
            comparison.Save($"artifacts/settings/comparison-{language}-{theme}.png");
        }
        Console.WriteLine("PASS: six settings pages and scrolled states, Chinese/English, light/dark; Mac/Windows comparison sheets in artifacts/settings");
    }
}
