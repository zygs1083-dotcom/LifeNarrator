using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class RuleInputWindow : Window
{
    readonly Settings settings;
    readonly Companion companion;
    readonly Func<Task> configure;
    readonly Texts text;
    readonly TextBox input;
    readonly StackPanel status;
    bool compiling;

    public RuleInputWindow(Settings settings, Companion companion, Func<Task> configure)
    {
        this.settings = settings; this.companion = companion; this.configure = configure; text = new Texts(settings);
        Width = 600; Height = 200; CanResize = false; SystemDecorations = SystemDecorations.None;
        Background = Brushes.Transparent; TransparencyLevelHint = [WindowTransparencyLevel.Transparent];
        Topmost = true; ShowInTaskbar = false; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Views.Font(settings); Title = text["input.title"];
        AutomationProperties.SetAutomationId(this, "rule-panel");
        input = new TextBox { Watermark = text["input.placeholder"], FontSize = 20, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0) };
        AutomationProperties.SetAutomationId(input, "rule-panel-input"); AutomationProperties.SetName(input, text["input.title"]);
        input.KeyDown += async (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; await Compile(); } };
        status = Views.Horizontal(); status.Spacing = 8;
        var content = Views.Stack(Views.Heading(text["input.title"], "\uE8F2"), input, Views.Line(), status); content.Spacing = 16;
        Content = Views.Surface(content, 20); SetIdle();
        Activated += (_, _) => input.Focus();
        Deactivated += (_, _) => { if (!compiling) Hide(); };
        KeyDown += (_, e) => { if (e.Key == Key.Escape && !compiling) Hide(); };
    }

    public void Open()
    {
        if (!compiling) { input.Text = ""; SetIdle(); }
        Show(); Activate(); input.Focus();
    }

    void SetIdle()
    {
        status.Children.Clear(); status.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right;
        status.Children.Add(Views.Caption(text["input.hint"]));
    }

    internal async Task Compile()
    {
        var value = input.Text?.Trim() ?? "";
        if (compiling || value.Length == 0) return;
        compiling = true; input.IsEnabled = false; status.Children.Clear(); status.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Stretch;
        var spinner = new ProgressBar { IsIndeterminate = true, Width = 18, Height = 4, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        status.Children.Add(spinner); status.Children.Add(Views.Caption(text["input.compiling"]));
        try
        {
            var rule = await companion.Call("rules.compile", new { input = value });
            settings.Rules = [..settings.Rules, rule]; await configure(); await companion.Refresh();
            status.Children.Clear();
            var check = Views.Icon("\uE73E", 15); Views.Hue(check, 150); check.Bind(TextBlock.ForegroundProperty, check.GetResourceObservable("AccentInk"));
            status.Children.Add(check); status.Children.Add(Views.Badge(text["input.saved"], 150));
            status.Children.Add(Views.Label(rule.GetProperty("label").GetProperty(settings.EffectiveLanguage).GetString()! + " · " + text["kind." + rule.GetProperty("kind").GetString()]));
        }
        catch (Exception failure)
        {
            status.Children.Clear();
            var message = Views.Label(failure.Message); message.MaxWidth = 525; message.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
            var icon = Views.Icon("\uE7BA"); icon.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
            status.Children.Add(icon); status.Children.Add(message);
        }
        finally { compiling = false; input.IsEnabled = true; input.Focus(); }
    }
}
