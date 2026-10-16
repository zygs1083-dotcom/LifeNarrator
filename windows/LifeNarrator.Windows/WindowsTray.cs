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
    [DllImport("user32.dll", SetLastError = true)] static extern nint CreateIconFromResourceEx(byte[] png, uint size, bool icon, uint version, int width, int height, uint flags);
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
        SetIcon(false, false); Notify(0); Notify(4);
    }

    public void Update(string tip, bool paused, bool error)
    {
        data.Tip = tip.Length > 127 ? tip[..127] : tip; SetIcon(paused, error); Notify(1);
    }

    void SetIcon(bool paused, bool error)
    {
        using var bitmap = AppIcons.Tray(paused, error);
        using var png = new MemoryStream(); bitmap.Save(png);
        var bytes = png.ToArray();
        var icon = CreateIconFromResourceEx(bytes, (uint)bytes.Length, true, 0x00030000, 32, 32, 0);
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
