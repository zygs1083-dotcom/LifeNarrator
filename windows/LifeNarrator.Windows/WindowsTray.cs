using System.ComponentModel;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;

namespace LifeNarrator.Windows;

// Avalonia 11 exposes only left clicks; own the Win32 callback so both buttons open the same card.
internal sealed class WindowsTray : IDisposable
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct IconData
    {
        public uint Size;
        public nint Window;
        public uint Id, Flags, Message;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Guid;
        public nint BalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIcon(uint operation, ref IconData data);
    [DllImport("user32.dll", SetLastError = true)] static extern nint CreateIcon(nint instance, int width, int height, byte planes, byte bits, byte[] mask, byte[] pixels);
    [DllImport("user32.dll")] static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint RegisterWindowMessage(string message);
    readonly Window window = new() { ShowInTaskbar = false, ShowActivated = false };
    IconData data;
    public nint Handle => data.Window;

    public WindowsTray(Action<PixelPoint> open)
    {
        var taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        if (taskbarCreated == 0) throw new Win32Exception();
        Win32Properties.AddWndProcHookCallback(window, (nint hwnd, uint message, nint wParam, nint lParam, ref bool handled) =>
        {
            if (message == 0x800 && wParam == 1 && lParam is 0x202 or 0x205)
            {
                handled = true;
                if (!GetCursorPos(out var point)) throw new Win32Exception();
                open(new PixelPoint(point.X, point.Y));
            }
            if (message == taskbarCreated) { Notify(0); Notify(4); }
            return 0;
        });
        data = new IconData { Size = (uint)Marshal.SizeOf<IconData>(), Window = window.TryGetPlatformHandle()!.Handle,
            Id = 1, Flags = 7, Message = 0x800, Tip = "LifeNarrator", Info = "", InfoTitle = "" };
        SetIcon(42, 166, 100); Notify(0); Notify(4);
    }

    public void Update(string tip, byte r, byte g, byte b)
    {
        data.Tip = tip.Length > 127 ? tip[..127] : tip; SetIcon(r, g, b); Notify(1);
    }

    void SetIcon(byte r, byte g, byte b)
    {
        var pixels = new byte[32 * 32 * 4]; var mask = new byte[128];
        for (var y = 0; y < 32; y++)
        for (var x = 0; x < 32; x++)
        {
            var visible = (x >= 3 && x < 29 && y >= 4 && y < 24) || (x >= 6 && x < 13 && y >= 24 && y < 29 - (x - 6));
            if (!visible) { mask[y * 4 + x / 8] |= (byte)(0x80 >> (x % 8)); continue; }
            var dot = y is >= 12 and <= 16 && (x is >= 8 and <= 10 or >= 15 and <= 17 or >= 22 and <= 24);
            var index = (y * 32 + x) * 4;
            pixels[index] = dot ? (byte)255 : b; pixels[index + 1] = dot ? (byte)255 : g;
            pixels[index + 2] = dot ? (byte)255 : r; pixels[index + 3] = 255;
        }
        var icon = CreateIcon(0, 32, 32, 1, 32, mask, pixels);
        if (icon == 0) throw new Win32Exception();
        var previous = data.Icon; data.Icon = icon;
        if (previous != 0) DestroyIcon(previous);
    }
    void Notify(uint operation)
    {
        if (!Shell_NotifyIcon(operation, ref data)) throw new InvalidOperationException("Shell_NotifyIcon failed: " + operation);
    }
    public void Dispose() { Notify(2); DestroyIcon(data.Icon); window.Close(); }
}
