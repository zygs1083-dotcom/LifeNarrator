using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;

namespace LifeNarrator.Windows;

internal sealed class AppearanceView : Grid
{
    public AppearanceView(Settings settings, Companion? companion, Func<Task> configure, Action<Func<Task>> run)
    {
        ColumnDefinitions = new ColumnDefinitions("*,*"); ColumnSpacing = 14;
        var text = new Texts(settings);
        var preview = new BubblePreview { Style = settings.ActiveStyle(companion?.Growth), Persona = settings.FontPersona(settings.Persona), Language = settings.EffectiveLanguage };
        void Change(Action change) => run(async () => { change(); preview.Style = settings.ActiveStyle(companion?.Growth); await configure(); });
        int? Required(string key, string value) => key == "emoji.selection" && value.Length > 0 ? 3 : BubbleStyle.UnlockLevel(value);
        bool Unlocked(string key, string value) => Required(key, value) is not { } level || companion?.Growth?.State.Level >= level;
        Control Choice(string key, string[] values, string selected, Action<string> change, Func<string, string>? title = null)
        {
            var items = values.Select(value => new ComboBoxItem { Content = (title == null ? text[key + "." + value] : title(value))
                + (Unlocked(key, value) ? "" : " · Lv." + Required(key, value)), Tag = value, IsEnabled = Unlocked(key, value) }).ToArray();
            var selector = new ComboBox { ItemsSource = items, SelectedItem = items.Single(i => (string)i.Tag! == selected), HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(selector, "appearance-" + key);
            selector.SelectionChanged += (_, _) => Change(() => change((string)((ComboBoxItem)selector.SelectedItem!).Tag!));
            return Views.Field(text[key], selector);
        }
        Control Segments(string key, string[] values, string selected, Action<string> change)
        {
            var group = new UniformGrid { Rows = 1, Columns = values.Length };
            var buttons = new List<(string Value, ToggleButton Button)>();
            foreach (var value in values)
            {
                var button = new ToggleButton { Content = text[key + "." + value], IsChecked = selected == value,
                    CornerRadius = new CornerRadius(5), Padding = new Thickness(8, 3), HorizontalContentAlignment = HorizontalAlignment.Center };
                AutomationProperties.SetAutomationId(button, "appearance-" + key + "-" + value); buttons.Add((value, button));
                button.Click += (_, _) =>
                {
                    foreach (var item in buttons) item.Button.IsChecked = item.Value == value;
                    Change(() => change(value));
                };
                group.Children.Add(button);
            }
            return Views.Field(text[key], group);
        }
        Control Locked(string unlock, int level)
        {
            var label = Views.Lock(text["growth.locked"].Replace("%d", level.ToString()).Replace("%@", text["growth.unlock." + unlock]));
            label.IsVisible = companion?.Growth?.State.Level < level || companion?.Growth == null; return label;
        }
        var fonts = new Dictionary<string, string>
        {
            ["persona"] = text["font.persona"], ["hannotate"] = "Hannotate SC", ["yuanti"] = "Yuanti SC", ["wawati"] = "Wawati SC",
            ["hanzipen"] = "Hanzipen SC", ["noteworthy"] = "Noteworthy", ["chalkboard"] = "Chalkboard SE", ["markerFelt"] = "Marker Felt"
        };
        var look = Views.Card(text["appearance.look"], "\uE8F2", 255, null,
            Choice("shape", BubbleStyle.Shapes, settings.BubbleShape, value => settings.BubbleShape = value), Locked("starBubble", 5),
            Segments("size", BubbleStyle.Sizes, settings.BubbleSize, value => settings.BubbleSize = value),
            Choice("font", BubbleStyle.Fonts, settings.BubbleFont, value => settings.BubbleFont = value, value => fonts[value]));
        var color = Views.Card(text["appearance.color"], "\uE790", 255, null,
            Choice("theme", BubbleStyle.Themes, settings.BubbleTheme, value => settings.BubbleTheme = value), Locked("starryTheme", 15),
            Views.Toggle(text["effects.outline"], settings.BubbleOutline, value => Change(() => settings.BubbleOutline = value)),
            Views.Toggle(text["effects.shadow"], settings.BubbleShadow, value => Change(() => settings.BubbleShadow = value)),
            Views.Toggle(text["effects.gradient"], settings.BubbleGradient, value => Change(() => settings.BubbleGradient = value)));
        var emoji = Choice("emoji.selection", new[] { "" }.Concat(BubbleStyle.ExtraEmoji).Append(settings.Emoji).Distinct().ToArray(), settings.Emoji, value => settings.Emoji = value,
            value => value.Length == 0 ? text["emoji.automatic"] : value);
        var motion = Views.Card(text["appearance.motion"], "\uE9D9", 255, null,
            Choice("animation", BubbleStyle.Animations, settings.BubbleAnimation, value => settings.BubbleAnimation = value),
            Segments("emoji", BubbleStyle.Densities, settings.EmojiDensity, value => settings.EmojiDensity = value), emoji, Locked("emoji", 3));
        var controls = Views.Stack(look, color, motion); controls.Spacing = 14;
        var previewCard = Views.Card(text["preview"], "\uE890", 255, text["preview.hint"], preview); previewCard.VerticalAlignment = VerticalAlignment.Top;
        SetColumn(previewCard, 1); Children.Add(controls); Children.Add(previewCard);
    }
}
