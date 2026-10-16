using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;

namespace LifeNarrator.Windows;

internal sealed class ShortcutRecorder : Grid
{
    public ShortcutRecorder(string title, HotKey? value, Texts text, Action<HotKey?> change, Action<bool>? recording)
    {
        ColumnDefinitions = new ColumnDefinitions("*,Auto"); Width = 200;
        var button = Views.Button(value?.ToString() ?? text["shortcut.record"], () => { });
        button.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Stretch;
        button.Padding = new Thickness(8, 2); button.CornerRadius = new CornerRadius(5);
        AutomationProperties.SetName(button, title); AutomationProperties.SetAutomationId(button, "recorder-" + title);
        var active = false;
        button.Click += (_, _) => { active = true; button.Content = text["shortcut.recording"]; recording?.Invoke(true); };
        button.LostFocus += (_, _) => { active = false; button.Content = value?.ToString() ?? text["shortcut.record"]; recording?.Invoke(false); };
        button.KeyDown += (_, e) =>
        {
            if (!active) return;
            e.Handled = true;
            if (e.Key == Key.Escape) { active = false; button.Content = value?.ToString() ?? text["shortcut.record"]; recording?.Invoke(false); return; }
            if (HotKey.FromKey(e.Key, e.KeyModifiers) is not { } shortcut) return;
            value = shortcut; button.Content = value.ToString(); active = false; change(value); recording?.Invoke(false);
        };
        var clear = Views.IconButton(text["shortcut.clear"], "\uE711", () =>
        { value = null; button.Content = text["shortcut.record"]; change(null); });
        SetColumn(clear, 1); Children.Add(button); Children.Add(clear);
        DetachedFromVisualTree += (_, _) => { if (active) recording?.Invoke(false); };
    }
}
