using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace LifeNarrator.Windows;

internal sealed class ChatWindow : Window
{
    readonly Settings settings;
    readonly Companion companion;
    readonly Texts text;
    readonly TextBlock heading = new(), context = new(), error = new();
    readonly Border level;
    readonly TextBlock thinking;
    readonly List<ChatTurn> conversation = [];
    readonly StackPanel turns = new() { Spacing = 14 };
    readonly ScrollViewer history;
    readonly TextBox input = new();
    readonly Button send;
    readonly StackPanel composer;
    readonly Avalonia.Controls.Primitives.ToggleButton screen = new();
    readonly DispatcherTimer fade;
    string? narration;
    bool sending;

    public ChatWindow(Settings settings, Companion companion)
    {
        this.settings = settings; this.companion = companion; text = new Texts(settings);
        Width = 400; Height = 520; CanResize = false;
        SystemDecorations = SystemDecorations.None; Background = Brushes.Transparent;
        TransparencyLevelHint = [WindowTransparencyLevel.Transparent]; FontFamily = Views.Font(settings);
        Topmost = true; ShowInTaskbar = false; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        AutomationProperties.SetAutomationId(this, "chat");
        heading.FontSize = 15; heading.FontWeight = FontWeight.SemiBold;
        var labels = Views.Stack(heading, Views.Caption(text["chat.subtitle"])); labels.Spacing = 3;
        var identity = Views.Horizontal(new Image { Source = AppIcons.Image, Width = 42, Height = 42 }, labels); identity.Spacing = 10;
        labels.VerticalAlignment = VerticalAlignment.Center;
        level = Views.Badge("");
        var header = Views.Row(identity, level); header.Margin = new Thickness(16);
        context.TextWrapping = error.TextWrapping = TextWrapping.Wrap;
        error.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        error.Classes.Add("caption"); error.IsVisible = false;
        context.Classes.Add("caption"); context.Margin = new Thickness(10);
        thinking = Views.Caption(text["chat.thinking"]); thinking.IsVisible = false;
        history = new ScrollViewer { Content = turns, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        turns.Margin = new Thickness(16); turns.Spacing = 16;
        input.Watermark = text["chat.placeholder"]; input.Background = Brushes.Transparent; input.BorderThickness = new Thickness(0); input.Padding = new Thickness(0);
        input.MaxHeight = 60; input.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetName(input, text["chat.placeholder"]); AutomationProperties.SetAutomationId(input, "chat-input");
        send = Views.IconButton(text["chat.send"], "\uE96D", () => SendInput());
        var arrow = new Avalonia.Controls.Shapes.Path { Data = StreamGeometry.Parse("M12,18 L12,6 M7,11 L12,6 L17,11"), Stroke = Brushes.White, StrokeThickness = 2 };
        var circle = new Avalonia.Controls.Shapes.Ellipse { Opacity = .55 };
        circle.Bind(Avalonia.Controls.Shapes.Shape.FillProperty, this.GetResourceObservable("AccentInk"));
        var sendIcon = new Panel { Width = 24, Height = 24 }; sendIcon.Children.Add(circle); sendIcon.Children.Add(arrow); send.Content = sendIcon;
        send.Bind(Button.ForegroundProperty, this.GetResourceObservable("AccentInk")); send.Padding = new Thickness(0);
        AutomationProperties.SetAutomationId(send, "chat-send");
        input.TextChanged += (_, _) => send.IsEnabled = !sending && !string.IsNullOrWhiteSpace(input.Text);
        input.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; SendInput(); } };
        var quick = Views.Horizontal(); quick.Spacing = 6;
        foreach (var key in new[] { "again", "quiet", "more", "recall" })
        {
            var reply = text["chat.quick." + key];
            var button = Views.Button(reply, () => SendInput(reply));
            button.FontSize = 11; button.Padding = new Thickness(10, 6); quick.Children.Add(button);
        }
        screen.Content = text["chat.screen"]; screen.FontSize = 11;
        screen.Theme = (Avalonia.Styling.ControlTheme)Application.Current!.FindResource("Checkbox")!;
        AutomationProperties.SetName(screen, text["chat.screen"]);
        AutomationProperties.SetAutomationId(screen, "chat-screen");
        var entry = new Border { Child = Views.Row(input, send), Padding = new Thickness(10), CornerRadius = new CornerRadius(12) };
        entry.Bind(Border.BackgroundProperty, this.GetResourceObservable("Paper"));
        var quickScroll = new ScrollViewer { Content = quick, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        composer = Views.Stack(error, quickScroll, entry, screen); composer.Margin = new Thickness(16);
        if (settings.Provider.Kind == "api" && Catalog.Providers.Single(p => p.Id == settings.Provider.PresetId).Group != "local")
            composer.Children.Add(Views.Caption(text["chat.privacy"]));
        var contextCard = new Border { Child = context, CornerRadius = new CornerRadius(10), Margin = new Thickness(16, 12, 16, 0) };
        contextCard.Bind(Border.BackgroundProperty, this.GetResourceObservable("Soft"));
        contextCard.Bind(IsVisibleProperty, context.GetObservable(IsVisibleProperty));
        var layout = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,*,Auto,Auto") };
        layout.Children.Add(header);
        var line = Views.Line(); Grid.SetRow(line, 1); layout.Children.Add(line);
        Grid.SetRow(contextCard, 2); layout.Children.Add(contextCard);
        Grid.SetRow(history, 3); layout.Children.Add(history);
        thinking.Margin = new Thickness(16, 0); Grid.SetRow(thinking, 4); layout.Children.Add(thinking);
        Grid.SetRow(composer, 5); layout.Children.Add(composer); Content = Views.Surface(layout);
        send.IsEnabled = false;
        fade = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, Fade);
        Deactivated += (_, _) => fade.Start();
        Activated += (_, _) => { fade.Stop(); Opacity = 1; input.Focus(); };
        Closed += (_, _) => { fade.Stop(); companion.Changed -= RefreshIdentity; };
        companion.Changed += RefreshIdentity;
        RefreshIdentity();
    }

    void Fade(object? sender, EventArgs args)
    {
        Opacity = Math.Max(0, Opacity - .1);
        if (Opacity == 0) { fade.Stop(); Hide(); }
    }

    public async Task Open(string? narration = null, PixelPoint? near = null)
    {
        fade.Stop(); Opacity = 1; this.narration = narration; screen.IsChecked = false;
        RefreshIdentity();
        context.Text = narration == null ? "" : text["chat.context"] + narration; context.IsVisible = narration != null;
        var items = (await companion.Call("chat.history", new { })).Read<ChatTurn[]>();
        conversation.Clear(); conversation.AddRange(items); RenderHistory();
        Show();
        if (near is { } point)
        {
            var area = Screens.ScreenFromPoint(point)!.WorkingArea;
            var scale = Screens.ScreenFromPoint(point)!.Scaling;
            Position = new PixelPoint(Math.Clamp(point.X + 12, area.X, Math.Max(area.X, area.Right - (int)(Width * scale))),
                Math.Clamp(point.Y, area.Y, Math.Max(area.Y, area.Bottom - (int)(Height * scale))));
        }
        Activate(); input.Focus(); history.ScrollToEnd();
    }

    void RefreshIdentity()
    {
        Title = text["chat.title"];
        heading.Text = companion.Name(settings);
        ((TextBlock)level.Child!).Text = "Lv." + (companion.Growth?.State.Level ?? 1);
    }

    async void SendInput(string? quick = null)
    {
        try { await Send(quick ?? input.Text ?? ""); }
        catch (Exception failure) { error.Text = failure.Message; error.IsVisible = true; }
    }

    internal async Task Send(string message)
    {
        message = message.Trim();
        if (sending || message.Length == 0) return;
        sending = true; composer.IsEnabled = false; error.IsVisible = false; thinking.IsVisible = true;
        try
        {
            var turn = (await companion.Call("chat.send", new { text = message, narration, includeScreen = screen.IsChecked == true })).Read<ChatTurn>();
            conversation.Add(turn);
            if (conversation.Count > 50) conversation.RemoveAt(0);
            RenderHistory(); input.Text = ""; error.Text = "";
            await companion.Refresh();
            history.ScrollToEnd();
        }
        finally { thinking.IsVisible = false; sending = false; composer.IsEnabled = true; send.IsEnabled = !string.IsNullOrWhiteSpace(input.Text); input.Focus(); }
    }

    void RenderHistory()
    {
        turns.Children.Clear();
        if (conversation.Count == 0)
        {
            var empty = Views.Label(text["chat.empty"]); empty.TextAlignment = TextAlignment.Center; empty.Margin = new Thickness(0, 28);
            empty.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("Muted")); turns.Children.Add(empty);
        }
        foreach (var turn in conversation) Append(turn);
    }

    void Append(ChatTurn turn)
    {
        var user = new Border { Child = Views.Label(turn.User), Padding = new Thickness(12, 8),
            CornerRadius = new CornerRadius(12), HorizontalAlignment = HorizontalAlignment.Right, MaxWidth = 300 };
        user.Bind(Border.BackgroundProperty, this.GetResourceObservable("Paper"));
        var reply = new BubbleVisual(turn.Id, turn.Reply, [], settings.EffectiveLanguage,
            settings.ActiveStyle(companion.Growth), settings.FontPersona(settings.Persona), maxWidth: 240);
        reply.HorizontalAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetName(reply, turn.Reply);
        var group = Views.Stack(user, reply); group.Spacing = 10;
        if (turn.Notice != null) group.Children.Add(Views.Caption(turn.Notice));
        turns.Children.Add(group);
    }
}
