using Avalonia;
using Avalonia.Animation.Easings;

namespace LifeNarrator.Windows;

internal readonly record struct BubbleMotion(double Opacity, double Scale, Vector Offset);

internal static class BubbleTransitions
{
    static readonly SplineEasing EaseOut = new(0, 0, .58, 1);
    static readonly SplineEasing EaseIn = new(.42, 0, 1, 1);
    public static double EntranceDuration(string animation) => animation switch
    { "fade" => .18, "bounce" => .6, "slide" => .45, "pop" => .4, _ => throw new ArgumentOutOfRangeException(nameof(animation)) };
    public static double ExitDuration(string animation) => animation switch
    { "fade" => .6, "bounce" => .16, "slide" => .2, "pop" => .15, _ => throw new ArgumentOutOfRangeException(nameof(animation)) };
    public static double DecorProgress(double elapsed) => EaseOut.Ease(Math.Clamp(elapsed / .24, 0, 1));
    static double Spring(double time, double response, double damping)
    {
        var omega = 2 * Math.PI / response;
        var damped = omega * Math.Sqrt(1 - damping * damping);
        return 1 - Math.Exp(-damping * omega * time) * (Math.Cos(damped * time) + damping * omega / damped * Math.Sin(damped * time));
    }
    public static BubbleMotion Sample(string animation, double elapsed, bool leaving, Vector slide, bool reduceMotion = false)
    {
        if (reduceMotion) animation = "fade";
        if (leaving)
        {
            var p = EaseIn.Ease(Math.Clamp(elapsed / ExitDuration(animation), 0, 1));
            return new(1 - p, animation switch { "bounce" => 1 - .4 * p, "pop" => 1 - .1 * p, _ => 1 }, animation == "slide" ? slide * p : default);
        }
        elapsed = Math.Max(0, elapsed);
        var opacity = EaseOut.Ease(Math.Clamp(elapsed / (animation == "bounce" ? .1 : .18), 0, 1));
        var progress = animation switch
        {
            "fade" => EaseOut.Ease(Math.Clamp(elapsed / .18, 0, 1)),
            "bounce" => Spring(elapsed, .42, .55), "slide" => Spring(elapsed, .35, .8), "pop" => Spring(elapsed, .30, .70),
            _ => throw new ArgumentOutOfRangeException(nameof(animation))
        };
        if (elapsed >= EntranceDuration(animation)) progress = 1;
        if (animation is "slide" or "pop") opacity = Math.Clamp(progress, 0, 1);
        return new(opacity, reduceMotion ? 1 : animation switch
        { "fade" => .96 + .04 * progress, "bounce" => .3 + .7 * progress, "pop" => .5 + .5 * progress, _ => 1 },
            animation == "slide" ? slide * (1 - progress) : default);
    }

    public static Vector Slide(Rect frame, Rect window) => new (double Distance, Vector Offset)[]
    {
        (frame.Left - window.Left, new(-24, 0)), (window.Right - frame.Right, new(24, 0)),
        (frame.Top - window.Top, new(0, -24)), (window.Bottom - frame.Bottom, new(0, 24))
    }.MinBy(e => e.Distance).Offset;
}
