using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;

namespace LifeNarrator.Windows;

internal sealed class GrowthCard : StackPanel
{
    public GrowthCard(Settings settings, Companion companion, Func<Task> configure, Action<Func<Task>> run)
    {
        var text = new Texts(settings); Spacing = 10;
        if (companion.Growth is not { } growth) { Children.Add(Views.Caption(text["chat.thinking"])); return; }
        var heading = Views.Label("Lv." + growth.State.Level + " · " + growth.Title); heading.FontSize = 20;
        var xp = Views.Label(growth.State.Experience + (growth.NextLevelExperience is { } next ? " / " + next : "") + " XP");
        AutomationProperties.SetName(xp, text["growth.experience"]);
        var start = growth.State.Level == 1 ? 0 : 40 * growth.State.Level * growth.State.Level;
        var fraction = growth.NextLevelExperience is { } limit ? (double)(growth.State.Experience - start) / (limit - start) : 1;
        var bar = new Border { Height = 6, CornerRadius = new CornerRadius(3), ClipToBounds = true,
            Child = new Border { Width = 240 * fraction, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(3),
                Background = Avalonia.Media.Brush.Parse("#F55DC2") } };
        bar.SizeChanged += (_, _) => ((Border)bar.Child!).Width = bar.Bounds.Width * fraction;
        bar.Bind(Border.BackgroundProperty, this.GetResourceObservable("Soft"));
        var stats = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var (key, value) in new[] { ("daysKnown", growth.DaysKnown), ("streak", growth.State.ConsecutiveDays),
            ("narrations", growth.State.Narrations), ("chats", growth.State.ChatMessages) })
            stats.Children.Add(new Border { Width = 155, Padding = new Thickness(0, 6),
                Child = Views.Stack(Views.Label(value.ToString()), Views.Caption(text["growth." + key])) });
        var name = new TextBox { Text = growth.Name, IsEnabled = growth.Has("spriteName") };
        AutomationProperties.SetName(name, text["growth.name"]); AutomationProperties.SetAutomationId(name, "sprite-name");
        var save = Views.Button(text["memory.save"], () => run(async () =>
        { await companion.Call("growth.setName", new { name = name.Text ?? "" }); await companion.Refresh(); }));
        save.IsEnabled = growth.Has("spriteName");
        var children = new List<Control> { heading, bar, xp, stats, Views.Field(text["growth.name"], Views.Row(name, save)) };
        var nextUnlock = growth.Unlocks.FirstOrDefault(u => u.Level > growth.State.Level);
        if (nextUnlock != null) children.Add(Views.Caption(text["growth.nextUnlock"].Replace("%d", nextUnlock.Level.ToString()).Replace("%@", nextUnlock.Name)));
        foreach (var unlock in growth.Unlocks.Where(u => !growth.Has(u.Id)))
            children.Add(Views.Caption("🔒 " + text["growth.locked"].Replace("%d", unlock.Level.ToString()).Replace("%@", unlock.Name)));
        Children.Add(Views.Card(text["growth.title"], children.ToArray()));
        var shapes = Views.Choices(new[] { ("automatic", text["shape.automatic"], ""), ("star", text["shape.star"], "") }, settings.BubbleShape,
            id => run(async () => { settings.BubbleShape = id; await configure(); }), disabled: growth.Has("starBubble") ? null : "star");
        var themes = Views.Choices(new[] { ("random", text["theme.random"], ""), ("starry", text["theme.starry"], "") }, settings.BubbleTheme,
            id => run(async () => { settings.BubbleTheme = id; await configure(); }), disabled: growth.Has("starryTheme") ? null : "starry");
        var emojis = new ComboBox { ItemsSource = new[] { text["emoji.automatic"], "✨", "🌷", "😺", "🥹", "🫶", "🌈", "🎉" },
            SelectedIndex = Array.IndexOf(new[] { "", "✨", "🌷", "😺", "🥹", "🫶", "🌈", "🎉" }, settings.Emoji),
            IsEnabled = growth.Has("emoji"), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(emojis, text["emoji.selection"]);
        emojis.SelectionChanged += (_, _) => run(async () =>
        { settings.Emoji = new[] { "", "✨", "🌷", "😺", "🥹", "🫶", "🌈", "🎉" }[emojis.SelectedIndex]; await configure(); });
        Children.Add(Views.Card(text["bubble.shape"], shapes));
        Children.Add(Views.Card(text["bubble.theme"], themes));
        Children.Add(Views.Card(text["emoji.selection"], emojis));
    }
}
