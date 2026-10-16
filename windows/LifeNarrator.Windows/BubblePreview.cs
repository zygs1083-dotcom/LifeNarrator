using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Styling;

namespace LifeNarrator.Windows;

public sealed class BubblePreview : Panel
{
    public static readonly StyledProperty<BubbleStyle> StyleProperty = AvaloniaProperty.Register<BubblePreview, BubbleStyle>(nameof(Style), new BubbleStyle());
    public static readonly StyledProperty<string> PersonaProperty = AvaloniaProperty.Register<BubblePreview, string>(nameof(Persona), "gentle");
    public static readonly StyledProperty<string> LanguageProperty = AvaloniaProperty.Register<BubblePreview, string>(nameof(Language), "zh");
    public BubbleStyle Style { get => GetValue(StyleProperty); set => SetValue(StyleProperty, value); }
    public string Persona { get => GetValue(PersonaProperty); set => SetValue(PersonaProperty, value); }
    public string Language { get => GetValue(LanguageProperty); set => SetValue(LanguageProperty, value); }
    BubbleVisual bubble = null!;
    public BubblePreview() { Width = 320; Height = 200; Rebuild(); }
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == StyleProperty || change.Property == PersonaProperty || change.Property == LanguageProperty) Rebuild();
    }
    void Rebuild()
    {
        Children.Clear();
        var group = Style.Theme == "random" ? BubbleColors.Random(160, 0) : BubbleColors.Palette(Style.Theme)[0];
        bubble = new BubbleVisual("preview", Language == "zh" ? "你的旁白小精灵" : "Your little narrator", ["✨", "🐱", "💬"], Language,
            Style, Persona, false, 1, false, group);
        if (Style.Shape == "speech") bubble.SetAppTail("topRight");
        Children.Add(new MockWindow());
        Children.Add(bubble);
        AutomationProperties.SetName(this, Language == "zh" ? "实时预览" : "Live preview");
        InvalidateMeasure(); InvalidateVisual();
    }
    sealed class MockWindow : Control
    {
        public override void Render(DrawingContext c)
        {
            var dark = ActualThemeVariant == ThemeVariant.Dark;
            var ink = dark ? Colors.White : Colors.Black;
            var line = new SolidColorBrush(ink, .12);
            c.DrawRectangle(new SolidColorBrush(Color.Parse(dark ? "#211C20" : "#FFF9F6")), new Pen(line, 1), new Rect(0, 0, 320, 200), 10, 10);
            foreach (var (x, color) in new[] { (14d, "#FF5F57"), (27d, "#FEBC2E"), (40d, "#28C840") })
                c.DrawEllipse(Brush.Parse(color), null, new Point(x, 11), 4, 4);
            c.DrawLine(new Pen(line, 1), new Point(0, 22), new Point(320, 22));
            var y = 38d;
            foreach (var fraction in new[] { .60, .80, .45 })
            { c.DrawRectangle(new SolidColorBrush(ink, .18), null, new Rect(16, y, 320 * fraction, 8), 4, 4); y += 20; }
        }
    }
    protected override Size ArrangeOverride(Size finalSize)
    {
        Children[0].Arrange(new Rect(finalSize));
        bubble.Arrange(new Rect(320 - 16 - bubble.Width, 34, bubble.Width, bubble.Height));
        return finalSize;
    }
}
