using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class AnchorDecor : Control
{
    public Rect Highlight { get; set; }
    public Rect BubbleFrame { get; set; }
    public string Side { get; set; } = "above";
    public string Shape { get; set; } = "text";
    public string Size { get; set; } = "small";
    public BubbleColors Group { get; set; }
    public bool Connector { get; set; }
    public bool Outside { get; set; }
    public bool Framed { get; set; }
    public double Progress { get; set; } = 1;

    public override void Render(DrawingContext c)
    {
        var stroke = new SolidColorBrush(Group.Stroke);
        var metrics = new BubbleMetrics(Size);
        if (Framed)
        {
            c.DrawRectangle(new SolidColorBrush(Group.Stroke, .08 * Progress), null, Highlight, 5, 5,
                new BoxShadows(new BoxShadow { Color = Color.FromArgb(77, 0, 0, 0), Blur = BubbleMetrics.BlurRadius(1.5) }));
            var box = new RectangleGeometry(Highlight, 5, 5);
            if (Progress == 0) return;
            box.TryGetSegment(0, box.ContourLength * Progress, true, out var segment);
            var traced = segment!;
            c.DrawGeometry(null, new Pen(new SolidColorBrush(Colors.White, .7), 2.5, lineCap: PenLineCap.Round), traced);
            c.DrawGeometry(null, new Pen(stroke, metrics.StrokeWidth, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round), traced);
        }
        if (!Connector) return;
        var (a, b) = Endpoints(BubbleFrame, Highlight, Side);
        var gap = Side switch
        {
            "above" => Highlight.Top - BubbleFrame.Bottom, "below" => BubbleFrame.Top - Highlight.Bottom,
            "right" => BubbleFrame.Left - Highlight.Right, _ => Highlight.Left - BubbleFrame.Right
        };
        if (Outside || Shape != "speech" && Shape != "cloud" && gap > 12)
            c.DrawLine(new Pen(stroke, 2, lineCap: PenLineCap.Round), a, b);
        else if (Shape == "cloud")
        {
            var delta = new Vector(b.X - a.X, b.Y - a.Y); var span = Math.Min(delta.Length, 40);
            var offsets = new[] { 4d, span / 2, span - 4 };
            var radii = new[] { .14, .09, .055 };
            for (var i = 0; i < 3; i++)
                c.DrawEllipse(new SolidColorBrush(Group.Fill), new Pen(stroke, metrics.StrokeWidth),
                    a + delta / delta.Length * offsets[i], radii[i] * BubbleFrame.Height, radii[i] * BubbleFrame.Height);
        }
    }

    internal static (Point Bubble, Point Highlight) Endpoints(Rect bubble, Rect highlight, string side) => side switch
    {
        "above" => (new Point(bubble.Center.X, bubble.Bottom), new Point(highlight.Center.X, highlight.Top)),
        "below" => (new Point(bubble.Center.X, bubble.Top), new Point(highlight.Center.X, highlight.Bottom)),
        "right" => (new Point(bubble.Left, bubble.Center.Y), new Point(highlight.Right, highlight.Center.Y)),
        _ => (new Point(bubble.Right, bubble.Center.Y), new Point(highlight.Left, highlight.Center.Y))
    };
}
