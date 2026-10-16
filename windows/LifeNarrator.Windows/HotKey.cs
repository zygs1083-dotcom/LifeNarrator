using Avalonia.Input;

namespace LifeNarrator.Windows;

internal sealed record HotKey(uint Modifiers, uint Key)
{
    public override string ToString() => ((Modifiers & 2) != 0 ? "Ctrl+" : "") + ((Modifiers & 1) != 0 ? "Alt+" : "")
        + ((Modifiers & 4) != 0 ? "Shift+" : "") + ((Modifiers & 8) != 0 ? "Win+" : "")
        + (Key == 0x20 ? "Space" : Key is >= 0x70 and <= 0x87 ? "F" + (Key - 0x6F) : ((char)Key).ToString());
    public static HotKey? FromKey(Avalonia.Input.Key key, KeyModifiers modifiers)
    {
        var code = key switch { >= Avalonia.Input.Key.A and <= Avalonia.Input.Key.Z => 0x41 + key - Avalonia.Input.Key.A,
            >= Avalonia.Input.Key.D0 and <= Avalonia.Input.Key.D9 => 0x30 + key - Avalonia.Input.Key.D0,
            >= Avalonia.Input.Key.F1 and <= Avalonia.Input.Key.F24 => 0x70 + key - Avalonia.Input.Key.F1,
            Avalonia.Input.Key.Space => 0x20, _ => 0 };
        if (code is not (>= 0x30 and <= 0x5A or >= 0x70 and <= 0x87 or 0x20) || modifiers == KeyModifiers.None) return null;
        return new HotKey((uint)(((modifiers & KeyModifiers.Alt) != 0 ? 1 : 0) | ((modifiers & KeyModifiers.Control) != 0 ? 2 : 0)
            | ((modifiers & KeyModifiers.Shift) != 0 ? 4 : 0) | ((modifiers & KeyModifiers.Meta) != 0 ? 8 : 0)), (uint)code);
    }
}
