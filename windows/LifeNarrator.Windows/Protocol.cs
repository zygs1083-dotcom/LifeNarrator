using System.Text.Json;
using System.Text.Json.Serialization;
using System.Globalization;
using Avalonia;

namespace LifeNarrator.Windows;

internal static class Protocol
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
        { Converters = { new WireDateConverter() } };
    public static T Read<T>(this JsonElement value) => value.Deserialize<T>(Json)!;
}

internal sealed class WireDateConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) => reader.GetDateTimeOffset();
    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
}

internal record Box(double X, double Y, double W, double H)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public Rect Rect => new(X, Y, W, H);
    public static Box From(Rect r) => new(r.X, r.Y, r.Width, r.Height);
    public Box Offset(double x, double y) => this with { X = X + x, Y = Y + y };
}
internal record Dimensions(double W, double H);
internal record TextSpan(int Location, int Length);
internal record TextLine(string Text, Box Rect, string Role);
internal record WindowGeometry(Box Frame, double ChromeHeight);
internal record Snapshot(string BundleId, string AppName, int Pid, string WindowTitle, string? Url, string? Host,
    Box WindowFrame, Box ContentFrame, int ScreenIndex, TextLine[] TextLines, string TextSource,
    Box[] SensitiveRects, bool SecureFocused, bool FullScreen, DateTimeOffset CapturedAt);
internal record Narration(string Id, string Text, string[] Emoji, string Language, string Persona,
    bool Framed, uint WindowID, WindowGeometry Window, Box? Anchor, Box? Line, Box[] Obstacles);
internal record Placement(Box Frame, Box? Highlight, bool Narrow, bool Covered, string PlacementName,
    Box?[]? StackFrames)
{
    public static Placement Read(JsonElement json) => new(json.GetProperty("frame").Read<Box>(),
        json.TryGetProperty("highlight", out var h) ? h.Read<Box?>() : null,
        json.GetProperty("narrow").GetBoolean(), json.GetProperty("covered").GetBoolean(),
        json.GetProperty("placement").GetString()!,
        json.TryGetProperty("stackFrames", out var s) ? s.Read<Box?[]>() : null);
}

// Keep each monitor's physical origin; scale distances from it in both directions.
internal record DisplayMap(PixelRect Bounds, PixelRect WorkArea, double Scaling)
{
    public Box Logical(PixelRect r) => Logical(new Box(r.X, r.Y, r.Width, r.Height));
    public Box Logical(Box r) => new(Bounds.X + (r.X - Bounds.X) / Scaling,
        Bounds.Y + (r.Y - Bounds.Y) / Scaling, r.W / Scaling, r.H / Scaling);
    public Box Physical(Box r) => new(Bounds.X + (r.X - Bounds.X) * Scaling,
        Bounds.Y + (r.Y - Bounds.Y) * Scaling, r.W * Scaling, r.H * Scaling);
}
