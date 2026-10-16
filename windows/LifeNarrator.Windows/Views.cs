using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;

namespace LifeNarrator.Windows;

internal static class Views
{
    public static void Hue(Control control, double degrees)
    {
        IBrush Color(double saturation, double value) => new SolidColorBrush(new HsvColor(1, degrees, saturation, value).ToRgb());
        control.Resources.ThemeDictionaries[ThemeVariant.Light] = new ResourceDictionary
        { ["Soft"] = Color(.22, 1), ["AccentInk"] = Color(.78, .4), ["Accent"] = Color(.62, .96) };
        control.Resources.ThemeDictionaries[ThemeVariant.Dark] = new ResourceDictionary
        { ["Soft"] = Color(.42, .34), ["AccentInk"] = Color(.30, 1), ["Accent"] = Color(.62, .96) };
    }
    public static StackPanel Stack(params Control[] controls)
    {
        var stack = new StackPanel { Spacing = 10 };
        foreach (var control in controls) stack.Children.Add(control);
        return stack;
    }
    public static StackPanel Horizontal(params Control[] controls)
    {
        var stack = Stack(controls); stack.Orientation = Orientation.Horizontal; return stack;
    }
    public static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
    public static TextBlock Caption(string text) { var label = Label(text); label.Classes.Add("caption"); return label; }
    public static TextBlock Icon(string glyph, double size = 13) => new()
    { Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = size, VerticalAlignment = VerticalAlignment.Center };
    public static Border Chip(string glyph)
    {
        var icon = Icon(glyph); icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.Bind(TextBlock.ForegroundProperty, icon.GetResourceObservable("AccentInk"));
        var chip = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(8), Child = icon };
        chip.Bind(Border.BackgroundProperty, chip.GetResourceObservable("Soft")); return chip;
    }
    public static Control Heading(string title, string glyph, string? caption = null)
    {
        var label = Label(title); label.FontSize = 15; label.FontWeight = FontWeight.SemiBold;
        var heading = Stack(Horizontal(Chip(glyph), label)); heading.Spacing = 6;
        label.VerticalAlignment = VerticalAlignment.Center;
        if (caption != null) heading.Children.Add(Caption(caption));
        return heading;
    }
    public static Border Card(string title, params Control[] controls) => Card(title, "\uE946", 320, null, controls);
    public static Border Card(string title, string glyph, double hue, string? caption, params Control[] controls)
        => Card(Heading(title, glyph, caption), hue, controls);
    public static Border Card(Control heading, double hue, params Control[] controls)
    {
        var body = Stack(heading, Stack(controls)); body.Spacing = 12;
        var card = new Border { Child = body }; card.Classes.Add("card"); Hue(card, hue); return card;
    }
    public static Border Badge(string text, double? hue = null)
    {
        var label = Label(text); label.FontSize = 12; label.FontWeight = FontWeight.SemiBold;
        label.Bind(TextBlock.ForegroundProperty, label.GetResourceObservable("AccentInk"));
        var badge = new Border { Child = label, CornerRadius = new CornerRadius(20), Padding = new Thickness(8, 3) };
        badge.Bind(Border.BackgroundProperty, badge.GetResourceObservable("Soft"));
        if (hue != null) Hue(badge, hue.Value); return badge;
    }
    public static Control Lock(string text) => Horizontal(Icon("\uE72E", 11), Caption(text));
    public static Grid Row(Control left, Control right)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10, MinHeight = 28 };
        left.VerticalAlignment = right.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(right, 1); grid.Children.Add(left); grid.Children.Add(right); return grid;
    }
    public static Control Field(string title, Control control)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 10, MinHeight = 28 };
        var label = Label(title); label.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(control, title);
        Grid.SetColumn(control, 1); grid.Children.Add(label); grid.Children.Add(control); return grid;
    }
    public static Button Button(string title, Action action)
    {
        var button = new Button { Content = title, HorizontalAlignment = HorizontalAlignment.Left };
        button.Click += (_, _) => action(); return button;
    }
    public static Button Primary(string title, Action action) { var button = Button(title, action); button.Classes.Add("primary"); return button; }
    public static Button IconButton(string title, string glyph, Action action)
    {
        var button = Button(title, action); button.Content = Icon(glyph); button.Padding = new Thickness(5);
        button.Background = Brushes.Transparent; button.BorderThickness = new Thickness(0);
        AutomationProperties.SetName(button, title); ToolTip.SetTip(button, title); return button;
    }
    public static ToggleButton Switch(string title, bool selected, Action<bool> change)
    {
        var toggle = new ToggleButton { IsChecked = selected, Theme = (ControlTheme)Application.Current!.FindResource("Switch")! };
        AutomationProperties.SetName(toggle, title);
        toggle.Click += (_, _) => change(toggle.IsChecked == true); return toggle;
    }
    public static Control Toggle(string title, bool selected, Action<bool> change) => Row(Label(title), Switch(title, selected, change));
    public static Control Choices(IEnumerable<(string Id, string Title, string Caption)> options, string selection,
        Action<string> change, string? disabled = null, bool tabs = false, Action? selectionChanged = null)
    {
        var panel = new WrapPanel { Orientation = Orientation.Horizontal };
        var buttons = new List<(string Id, ToggleButton Button)>();
        foreach (var option in options)
        {
            var body = Stack(); body.Spacing = 6;
            var title = option.Title;
            var space = title.IndexOf("  ", StringComparison.Ordinal);
            if (space > 0)
            {
                var emoji = Label(title[..space]); emoji.FontSize = 22; body.Children.Add(emoji); title = title[(space + 2)..];
            }
            var label = Label(title); label.FontWeight = FontWeight.SemiBold; body.Children.Add(label);
            if (option.Caption.Length > 0) body.Children.Add(Caption(option.Caption));
            var button = new ToggleButton { Content = body, CornerRadius = new CornerRadius(tabs ? 18 : 14),
                IsChecked = selection == option.Id, IsEnabled = option.Id != disabled, Width = tabs ? double.NaN : 224,
                MinHeight = tabs ? 30 : 110, Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 10, 0), HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalContentAlignment = VerticalAlignment.Top };
            AutomationProperties.SetName(button, title); AutomationProperties.SetAutomationId(button, (tabs ? "tab-" : "choice-") + option.Id);
            if (tabs) button.Classes.Add("tab");
            buttons.Add((option.Id, button));
            button.Click += (_, _) =>
            {
                foreach (var item in buttons) item.Button.IsChecked = item.Id == option.Id;
                change(option.Id); selectionChanged?.Invoke();
            };
            panel.Children.Add(button);
        }
        if (buttons.Count > 0) buttons[^1].Button.Margin = new Thickness(0);
        return panel;
    }
    public static void OpenURL(string url) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
}
