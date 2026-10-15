using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace LifeNarrator.Windows;

public sealed class BubbleSample : Control
{
    public override void Render(DrawingContext context)
    {
        base.Render(context);
        var outline = Brush.Parse("#F55DC2");
        context.DrawRectangle(Brush.Parse("#FFC7EC"), new Pen(outline, 2), new Rect(64, 48, 470, 112), 26, 26);
        var text = new FormattedText("又要上班了！", CultureInfo.GetCultureInfo("zh-CN"), FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Microsoft YaHei, Noto Sans CJK SC"), FontStyle.Normal, FontWeight.Bold), 42, Brushes.White);
        var geometry = text.BuildGeometry(new Point(88, 74))!;
        context.DrawGeometry(Brushes.White, new Pen(outline, 3), geometry);
        var emoji = new FormattedText("😩", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface("Segoe UI Emoji, Noto Color Emoji"), 46, Brushes.Black);
        context.DrawText(emoji, new Point(440, 73));
        context.DrawRectangle(null, new Pen(outline, 1), new Rect(90, 218, 390, 44), 5, 5);
    }
}
