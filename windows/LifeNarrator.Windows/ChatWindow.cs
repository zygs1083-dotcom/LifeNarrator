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
        Width = 420; Height = 580; MinWidth = 400; MinHeight = 500;
        Topmost = true; ShowInTaskbar = false; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        AutomationProperties.SetAutomationId(this, "chat");
        heading.FontSize = 17; heading.FontWeight = FontWeight.SemiBold;
        var identity = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        identity.Children.Add(new SpriteAvatar()); identity.Children.Add(heading);
        heading.VerticalAlignment = VerticalAlignment.Center;
        context.TextWrapping = error.TextWrapping = TextWrapping.Wrap;
        error.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("ErrorInk"));
        context.Classes.Add("caption");
        history = new ScrollViewer { Content = turns, Margin = new Thickness(0, 12) };
        input.Watermark = text["chat.placeholder"];
        AutomationProperties.SetName(input, text["chat.placeholder"]); AutomationProperties.SetAutomationId(input, "chat-input");
        send = Views.Button(text["chat.send"], () => SendInput());
        AutomationProperties.SetAutomationId(send, "chat-send");
        input.TextChanged += (_, _) => send.IsEnabled = !sending && !string.IsNullOrWhiteSpace(input.Text);
        input.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; SendInput(); } };
        var quick = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var key in new[] { "again", "quiet", "more", "recall" })
        {
            var reply = text["chat.quick." + key];
            var button = Views.Button(reply, () => SendInput(reply));
            button.FontSize = 12; button.Padding = new Thickness(8, 6); button.Margin = new Thickness(0, 0, 6, 6);
            quick.Children.Add(button);
        }
        screen.Content = text["chat.screen"];
        AutomationProperties.SetName(screen, text["chat.screen"]);
        AutomationProperties.SetAutomationId(screen, "chat-screen");
        composer = Views.Stack(error, quick, Views.Row(input, send), screen, Views.Caption(text["chat.privacy"]));
        var layout = new DockPanel { Margin = new Thickness(16) };
        var header = Views.Stack(identity, context); DockPanel.SetDock(header, Dock.Top); layout.Children.Add(header);
        DockPanel.SetDock(composer, Dock.Bottom); layout.Children.Add(composer); layout.Children.Add(history); Content = layout;
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
        heading.Text = companion.Name(settings) + "  ·  Lv." + (companion.Growth?.State.Level ?? 1) + "\n"
            + settings.Personas.Single(p => p.Id == settings.Persona).Name.Text(settings.EffectiveLanguage);
    }

    async void SendInput(string? quick = null)
    {
        try { await Send(quick ?? input.Text ?? ""); }
        catch (Exception failure) { error.Text = failure.Message; }
    }

    internal async Task Send(string message)
    {
        message = message.Trim();
        if (sending || message.Length == 0) return;
        sending = true; composer.IsEnabled = false; error.Text = text["chat.thinking"];
        try
        {
            var turn = (await companion.Call("chat.send", new { text = message, narration, includeScreen = screen.IsChecked == true })).Read<ChatTurn>();
            conversation.Add(turn);
            if (conversation.Count > 50) conversation.RemoveAt(0);
            RenderHistory(); input.Text = ""; error.Text = "";
            await companion.Refresh();
            history.ScrollToEnd();
        }
        finally { sending = false; composer.IsEnabled = true; send.IsEnabled = !string.IsNullOrWhiteSpace(input.Text); input.Focus(); }
    }

    void RenderHistory()
    {
        turns.Children.Clear();
        if (conversation.Count == 0) turns.Children.Add(Views.Caption(text["chat.empty"]));
        foreach (var turn in conversation) Append(turn);
    }

    void Append(ChatTurn turn)
    {
        var user = new Border { Child = Views.Label(turn.User), Padding = new Thickness(12, 8),
            CornerRadius = new CornerRadius(12), HorizontalAlignment = HorizontalAlignment.Right, MaxWidth = 300 };
        user.Bind(Border.BackgroundProperty, this.GetResourceObservable("Soft")); turns.Children.Add(user);
        var reply = new BubbleVisual(turn.Id, turn.Reply, [], settings.EffectiveLanguage,
            settings.ActiveStyle(companion.Growth) with { Shape = "rounded", Size = "small" }, settings.FontPersona(settings.Persona), narrow: true);
        AutomationProperties.SetName(reply, turn.Reply); turns.Children.Add(reply);
        if (turn.Notice != null) turns.Children.Add(Views.Caption(turn.Notice));
    }
}

internal sealed class SpriteAvatar : Control
{
    public SpriteAvatar() { Width = Height = 42; }
    public override void Render(DrawingContext context)
    {
        context.DrawRectangle(Brush.Parse("#F55DC2"), null, new Rect(0, 0, 42, 42), 10, 10);
        context.DrawRectangle(Brushes.FloralWhite, null, new Rect(7, 10, 28, 23), 8, 8);
        context.DrawGeometry(Brushes.FloralWhite, null, StreamGeometry.Parse("M 12,29 L 10,37 L 22,29 Z"));
        context.DrawEllipse(Brush.Parse("#2B2226"), null, new Point(16, 19), 1.5, 2.5);
        context.DrawEllipse(Brush.Parse("#2B2226"), null, new Point(26, 19), 1.5, 2.5);
        context.DrawGeometry(null, new Pen(Brush.Parse("#2B2226"), 1.5), StreamGeometry.Parse("M 18,25 Q 21,30 24,25"));
    }
}
