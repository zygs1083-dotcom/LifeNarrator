using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class TrayMenuWindow : Window
{
    readonly Settings settings;
    readonly Companion companion;
    readonly Func<Task> configure, chat, input, quit, restart;
    readonly Action<int> showSettings;
    readonly Updater updater;
    readonly Texts text;
    string? failure;
    bool ocrUnavailable, expanded;
    UpdateFailure? updateFailure;
    PixelPoint anchor;

    public TrayMenuWindow(Settings settings, Companion companion, Func<Task> configure, Func<Task> chat, Func<Task> input,
        Action<int> showSettings, Func<Task> quit, Updater updater, Func<Task> restart)
    {
        this.settings = settings; this.companion = companion; this.configure = configure; this.chat = chat; this.input = input;
        this.showSettings = showSettings; this.quit = quit; this.updater = updater; this.restart = restart; text = new Texts(settings);
        Width = 240; SizeToContent = SizeToContent.Height; CanResize = false; ShowInTaskbar = false; Topmost = true;
        SystemDecorations = SystemDecorations.None; Background = Brushes.Transparent; TransparencyLevelHint = [WindowTransparencyLevel.Transparent];
        AutomationProperties.SetAutomationId(this, "tray-menu");
        SizeChanged += (_, _) => { if (IsVisible) PositionNear(); };
        Deactivated += (_, _) => Hide();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Hide();
            if (e.KeyModifiers == KeyModifiers.Control && e.Key == Key.Q) { e.Handled = true; Hide(); Run(quit); }
            if (e.KeyModifiers == KeyModifiers.Control && e.Key == Key.OemComma) { e.Handled = true; Hide(); showSettings(SettingsWindow.SpriteTab); }
        };
        Refresh(null, false, null);
    }

    public void Open(PixelPoint point)
    {
        expanded = false; Render();
        anchor = point; MaxHeight = Screens.ScreenFromPoint(point)!.WorkingArea.Height / Screens.ScreenFromPoint(point)!.Scaling;
        Show(); UpdateLayout(); PositionNear(); Activate();
    }

    void PositionNear()
    {
        var screen = Screens.ScreenFromPoint(anchor)!; var area = screen.WorkingArea; var scale = screen.Scaling;
        Position = new PixelPoint(Math.Clamp(anchor.X - (int)(Width * scale), area.X, Math.Max(area.X, area.Right - (int)(Width * scale))),
            Math.Clamp(anchor.Y - (int)(Bounds.Height * scale), area.Y, Math.Max(area.Y, area.Bottom - (int)(Bounds.Height * scale))));
    }

    public void Refresh(string? failure, bool ocrUnavailable, UpdateFailure? updateFailure)
    {
        this.failure = failure; this.ocrUnavailable = ocrUnavailable; this.updateFailure = updateFailure; Render();
    }

    void Render()
    {
        FontFamily = Views.Font(settings); Title = text["app.name"];
        var name = Views.Label(companion.Growth is { } g && g.Has("spriteName") && g.Name.Trim().Length > 0 ? g.Name.Trim() : text["tab.sprite"]); name.FontSize = 15; name.FontWeight = FontWeight.SemiBold;
        name.TextWrapping = TextWrapping.NoWrap; name.TextTrimming = TextTrimming.CharacterEllipsis; name.MaxWidth = 120;
        var identity = Views.Horizontal(new Image { Source = AppIcons.Image, Width = 26, Height = 26 }, name); identity.Spacing = 8;
        var body = Views.Stack(Views.Row(identity, Views.Badge("Lv." + (companion.Growth?.State.Level ?? 1)))); body.Spacing = 10;
        if (companion.Growth is { } growth)
        {
            var start = growth.State.Level == 1 ? 0 : 40 * growth.State.Level * growth.State.Level;
            body.Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Height = 6,
                Value = growth.NextLevelExperience is { } limit ? (double)(growth.State.Experience - start) / (limit - start) : 1 });
            body.Children.Add(Views.Caption(growth.State.Experience + (growth.NextLevelExperience is { } next ? " / " + next + " XP" : " XP")));
        }
        var status = settings.Paused ? text["paused"] : text["menu.onDuty"] + " · " + text["liveliness." + settings.Liveliness];
        var more = Views.IconButton(text["menu.details"], "\uE712", () => { expanded = !expanded; Render(); });
        AutomationProperties.SetAutomationId(more, "tray-details");
        if (failure != null || ocrUnavailable || updateFailure != null) more.Bind(Button.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        var badge = Views.Badge(status, settings.Paused ? 42 : 150); badge.HorizontalAlignment = HorizontalAlignment.Left;
        body.Children.Add(Views.Row(badge, more));
        var duty = Views.Switch(text["sprite.onDuty"], !settings.Paused, value => Run(async () => { settings.Paused = !value; await configure(); Render(); }));
        AutomationProperties.SetAutomationId(duty, "tray-duty"); body.Children.Add(Views.Row(Views.Label(text["sprite.onDuty"]), duty));
        if (expanded)
        {
            var levels = new[] { "quiet", "lively", "rowdy" };
            var lively = new ComboBox { ItemsSource = levels.Select(id => text["liveliness." + id]).ToArray(), SelectedIndex = Array.IndexOf(levels, settings.Liveliness) };
            lively.SelectionChanged += (_, _) => Run(async () => { settings.Liveliness = levels[lively.SelectedIndex]; await configure(); });
            body.Children.Add(Views.Stack(Views.Caption(text["liveliness"]), lively));
            var presets = settings.Personas;
            var persona = new ComboBox { ItemsSource = presets.Select(p => p.Name.Text(settings.EffectiveLanguage)).ToArray(), SelectedIndex = Array.FindIndex(presets, p => p.Id == settings.Persona) };
            persona.SelectionChanged += (_, _) => Run(async () => { settings.Persona = presets[persona.SelectedIndex].Id; await configure(); });
            body.Children.Add(Views.Stack(Views.Caption(text["persona"]), persona));
            if (ocrUnavailable) body.Children.Add(Views.Caption(text["ocr.unavailable"]));
            if (failure != null)
            {
                body.Children.Add(Views.Caption(text["error.details"] + ": " + failure));
                body.Children.Add(ActionRow("brain.restart", "\uE72C", null, restart));
            }
            if (updateFailure != null)
                body.Children.Add(ActionRow("updates.installFailed", "\uE7BA", null, () => { Views.OpenURL(updateFailure.LogPath); return Task.CompletedTask; }));
            body.Children.Add(ActionRow("updates.check", "\uE895", null, () => { showSettings(SettingsWindow.GeneralTab); return Task.CompletedTask; }));
        }
        if (updater.State == UpdateState.Available)
        {
            var update = ActionRow("updates.available", "\uE895", null, () => { showSettings(SettingsWindow.GeneralTab); return Task.CompletedTask; });
            update.Content = Views.Label(text["updates.available"].Replace("%@", updater.Release!.Tag)); body.Children.Add(update);
        }
        body.Children.Add(Views.Line());
        body.Children.Add(ActionRow("chat.open", "\uE8F2", settings.ChatShortcut?.ToString(), chat));
        body.Children.Add(ActionRow("input.open", "\uE70F", settings.InputShortcut?.ToString(), input));
        body.Children.Add(ActionRow("settings", "\uE713", "Ctrl+,", () => { showSettings(SettingsWindow.SpriteTab); return Task.CompletedTask; }));
        body.Children.Add(ActionRow("quit", "\uE7E8", "Ctrl+Q", quit));
        Content = Views.Surface(new ScrollViewer { Content = body, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled }, 16);
    }

    Button ActionRow(string key, string glyph, string? shortcut, Func<Task> action)
    {
        var icon = Views.Icon(glyph); icon.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("AccentInk"));
        var label = Views.Label(text[key]); label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis;
        var left = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 8 };
        left.Children.Add(icon); Grid.SetColumn(label, 1); left.Children.Add(label);
        var hint = Views.Caption(shortcut ?? ""); hint.FontSize = 10;
        var row = Views.Row(left, hint); row.MinHeight = 28;
        var button = Views.Button(text[key], () => { Hide(); Run(action); }); button.Content = row;
        button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        button.Padding = new Thickness(0); button.BorderThickness = new Thickness(0); button.Background = Brushes.Transparent; button.FontWeight = FontWeight.Normal;
        AutomationProperties.SetName(button, text[key]); AutomationProperties.SetAutomationId(button, "tray-" + key); return button;
    }
    async void Run(Func<Task> action)
    {
        try { await action(); }
        catch (Exception error) { failure = error.Message; expanded = true; Render(); Show(); Activate(); }
    }
}
