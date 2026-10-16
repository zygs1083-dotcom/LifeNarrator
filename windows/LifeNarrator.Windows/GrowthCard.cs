using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class GrowthCard : StackPanel
{
    public GrowthCard(Settings settings, Companion companion, Func<Task> configure, Action<Func<Task>> run)
    {
        var text = new Texts(settings);
        var children = new List<Control>();
        if (companion.Growth is { } growth)
        {
            var nameLabel = Views.Label(growth.Has("spriteName") && growth.Name.Length > 0 ? growth.Name : text["tab.sprite"]); nameLabel.FontWeight = FontWeight.SemiBold; nameLabel.FontSize = 15; nameLabel.VerticalAlignment = VerticalAlignment.Center;
            var title = Views.Caption(growth.Title); title.VerticalAlignment = VerticalAlignment.Center;
            children.Add(Views.Horizontal(Views.Chip("\uE8F2"), nameLabel, Views.Badge("Lv." + growth.State.Level), title));
            var start = growth.State.Level == 1 ? 0 : 40 * growth.State.Level * growth.State.Level;
            var fraction = growth.NextLevelExperience is { } limit ? (double)(growth.State.Experience - start) / (limit - start) : 1;
            var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = fraction, Height = 6 };
            AutomationProperties.SetName(bar, text["growth.experience"]); children.Add(bar);
            children.Add(Views.Caption(growth.State.Experience + (growth.NextLevelExperience is { } next ? " / " + next + " XP" : " XP · " + text["growth.maxLevel"])));
            var nextUnlock = growth.Unlocks.FirstOrDefault(u => u.Level > growth.State.Level);
            if (nextUnlock != null) children.Add(Views.Caption(text["growth.nextUnlock"].Replace("%d", nextUnlock.Level.ToString()).Replace("%@", nextUnlock.Name)));
            var stats = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24, Margin = new Thickness(0, 4) };
            foreach (var (key, value) in new[] { ("daysKnown", growth.DaysKnown), ("streak", growth.State.ConsecutiveDays),
                ("narrations", growth.State.Narrations), ("chats", growth.State.ChatMessages) })
            {
                var number = Views.Label(value.ToString()); number.FontWeight = FontWeight.SemiBold; number.FontSize = 12;
                var stat = Views.Stack(number, Views.Caption(text["growth." + key])); stat.Spacing = 4; stats.Children.Add(stat);
            }
            children.Add(stats);
            var name = new TextBox { Text = growth.Name, Watermark = text["tab.sprite"], IsEnabled = growth.Has("spriteName"), Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
            AutomationProperties.SetName(name, text["growth.name"]); AutomationProperties.SetAutomationId(name, "sprite-name");
            name.LostFocus += (_, _) => { if (name.Text != growth.Name) run(async () =>
                { await companion.Call("growth.setName", new { name = name.Text ?? "" }); await companion.Refresh(); }); };
            children.Add(Views.Field(text["growth.name"], name));
            if (!growth.Has("spriteName")) children.Add(Views.Lock(text["growth.locked"].Replace("%d", "2").Replace("%@", growth.Unlocks.Single(u => u.Id == "spriteName").Name)));
        }
        Children.Add(Views.Card(text["growth.title"], "\uE8BE", 320, null, children.ToArray()));
    }
}
