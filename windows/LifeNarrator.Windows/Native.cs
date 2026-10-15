using System.ComponentModel;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.Platform;

namespace LifeNarrator.Windows;

internal static partial class Native
{
    const int ExStyle = -20;
    const long Layered = 0x80000, Transparent = 0x20, Topmost = 0x8, ToolWindow = 0x80, NoActivate = 0x8000000;
    public const uint OverlayExtendedStyles = (uint)(Layered | Transparent | ToolWindow | NoActivate);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetLayeredWindowAttributes(nint window, uint key, byte alpha, uint flags);
    public static void EnableLayeredWindow(nint window)
    {
        if (!SetLayeredWindowAttributes(window, 0, 255, 2)) throw new Win32Exception();
    }
    [DllImport("user32.dll")] public static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] static extern nint GetWindowLongPtrW(nint window, int index);
    [DllImport("user32.dll", SetLastError = true)] static extern nint SetWindowLongPtrW(nint window, int index, nint value);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowPos(nint window, nint after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern nint GetDC(nint window);
    [DllImport("user32.dll")] static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll")] static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(nint dc);
    [DllImport("gdi32.dll")] static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint obj);
    [DllImport("gdi32.dll", SetLastError = true)] static extern nint CreateDIBSection(nint dc, ref BitmapInfo info, uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32.dll", SetLastError = true)] static extern bool BitBlt(nint target, int x, int y, int width, int height, nint source, int sx, int sy, uint operation);
    [StructLayout(LayoutKind.Sequential)]
    struct BitmapInfo
    {
        public uint Size;
        public int Width, Height;
        public ushort Planes, BitCount;
        public uint Compression, SizeImage;
        public int XPels, YPels;
        public uint Used, Important;
    }
    [StructLayout(LayoutKind.Sequential)] public struct CursorPoint { public int X, Y; }
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetCursorPos(out CursorPoint point);
    public static void SetOverlayInteractive(nint window, bool interactive)
    {
        var style = GetWindowLongPtrW(window, ExStyle).ToInt64();
        Marshal.SetLastPInvokeError(0);
        if (SetWindowLongPtrW(window, ExStyle, (nint)(interactive ? style & ~Transparent : style | Transparent)) == 0
            && Marshal.GetLastPInvokeError() != 0) throw new Win32Exception();
    }
    public static void ApplyOverlayStyles(nint window)
    {
        Marshal.SetLastPInvokeError(0);
        if (SetWindowLongPtrW(window, ExStyle, (nint)(GetWindowLongPtrW(window, ExStyle).ToInt64()
                | OverlayExtendedStyles)) == 0 && Marshal.GetLastPInvokeError() != 0)
            throw new Win32Exception();
        if (!SetWindowPos(window, -1, 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x20)) throw new Win32Exception();
    }
    public static Dictionary<string, bool> OverlayStyles(nint window)
    {
        var value = GetWindowLongPtrW(window, ExStyle).ToInt64();
        return new Dictionary<string, long> { ["WS_EX_LAYERED"] = Layered, ["WS_EX_TRANSPARENT"] = Transparent,
            ["WS_EX_TOPMOST"] = Topmost, ["WS_EX_TOOLWINDOW"] = ToolWindow, ["WS_EX_NOACTIVATE"] = NoActivate }
            .ToDictionary(x => x.Key, x => (value & x.Value) != 0);
    }
    [DllImport("user32.dll", SetLastError = true)] static extern bool PrintWindow(nint window, nint dc, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetClientRect(nint window, out WinRect rect);
    [DllImport("user32.dll", SetLastError = true)] static extern bool ClientToScreen(nint window, ref ClientPoint point);
    [StructLayout(LayoutKind.Sequential)] struct ClientPoint { public int X, Y; }
    public static Box ClientFrame(nint window)
    {
        if (!GetClientRect(window, out var rect)) throw new Win32Exception();
        var origin = new ClientPoint();
        if (!ClientToScreen(window, ref origin)) throw new Win32Exception();
        return rect.Box.Offset(origin.X, origin.Y);
    }
    internal record WindowImage(int Width, int Height, byte[] Pixels);
    public static WindowImage CaptureWindow(nint window)
    {
        if (!GetWindowRect(window, out var frame)) throw new Win32Exception();
        var width = frame.Right - frame.Left;
        var height = frame.Bottom - frame.Top;
        var screen = GetDC(0);
        var memory = CreateCompatibleDC(screen);
        nint bitmap = 0, old = 0;
        try
        {
            var info = new BitmapInfo { Size = (uint)Marshal.SizeOf<BitmapInfo>(), Width = width,
                Height = -height, Planes = 1, BitCount = 32 };
            bitmap = CreateDIBSection(screen, ref info, 0, out var bits, 0, 0);
            if (bitmap == 0) throw new Win32Exception();
            old = SelectObject(memory, bitmap);
            if (!PrintWindow(window, memory, 2)) throw new Win32Exception(); // PW_RENDERFULLCONTENT
            var pixels = new byte[checked(width * height * 4)];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            return new WindowImage(width, height, pixels);
        }
        finally
        {
            if (old != 0) SelectObject(memory, old);
            if (bitmap != 0) DeleteObject(bitmap);
            DeleteDC(memory); ReleaseDC(0, screen);
        }
    }
    public static void CaptureScreen(string path, PixelRect bounds)
    {
        var screen = GetDC(0);
        var memory = CreateCompatibleDC(screen);
        var info = new BitmapInfo { Size = (uint)Marshal.SizeOf<BitmapInfo>(), Width = bounds.Width,
            Height = -bounds.Height, Planes = 1, BitCount = 32 };
        var bitmap = CreateDIBSection(screen, ref info, 0, out var bits, 0, 0);
        if (bitmap == 0) throw new Win32Exception();
        var old = SelectObject(memory, bitmap);
        try
        {
            if (!BitBlt(memory, 0, 0, bounds.Width, bounds.Height, screen, bounds.X, bounds.Y, 0x40CC0020))
                throw new Win32Exception();
            using var image = new WriteableBitmap(bounds.Size, new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
            using (var buffer = image.Lock())
            {
                var row = new byte[bounds.Width * 4];
                for (var y = 0; y < bounds.Height; y++)
                {
                    Marshal.Copy(bits + y * row.Length, row, 0, row.Length);
                    Marshal.Copy(row, 0, buffer.Address + y * buffer.RowBytes, row.Length);
                }
            }
            image.Save(path);
        }
        finally { SelectObject(memory, old); DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(0, screen); }
    }
}
