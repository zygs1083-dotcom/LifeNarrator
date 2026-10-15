using System.ComponentModel;
using System.Runtime.InteropServices;

namespace LifeNarrator.Windows;

internal static partial class Native
{
    public delegate void WinEvent(nint hook, uint eventType, nint window, int objectID, int childID, uint thread, uint time);
    public delegate nint HookProc(int code, nint message, nint data);
    [DllImport("user32.dll", SetLastError = true)] public static extern nint SetWinEventHook(uint min, uint max,
        nint module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll", SetLastError = true)] public static extern nint SetWindowsHookExW(int id, HookProc callback, nint module, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] public static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern nint GetModuleHandleW(string? module);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowRect(nint window, out WinRect rect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetLastInputInfo(ref LastInput info);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetSystemPowerStatus(out PowerStatus status);
    [StructLayout(LayoutKind.Sequential)] public struct WinRect
    {
        public int Left, Top, Right, Bottom;
        public readonly Box Box => new(Left, Top, Right - Left, Bottom - Top);
    }
    [StructLayout(LayoutKind.Sequential)] public struct LastInput { public uint Size, Time; }
    [StructLayout(LayoutKind.Sequential)] public struct PowerStatus
    {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public uint BatteryLifeTime, BatteryFullLifeTime;
    }
    public static double IdleSeconds()
    {
        var info = new LastInput { Size = (uint)Marshal.SizeOf<LastInput>() };
        if (!GetLastInputInfo(ref info)) throw new Win32Exception();
        return unchecked((uint)Environment.TickCount - info.Time) / 1000.0;
    }
}

internal sealed class WindowEvents : IDisposable
{
    readonly Native.WinEvent windowEvent;
    readonly Native.HookProc keyboard, mouse;
    readonly nint foregroundHook, locationHook, keyboardHook, mouseHook;
    long lastKeyTicks = DateTimeOffset.UnixEpoch.UtcTicks;
    long scrollTicks;
    public DateTimeOffset LastTypedAt => new(Interlocked.Read(ref lastKeyTicks), TimeSpan.Zero);
    public DateTimeOffset ScrollAt => new(Interlocked.Read(ref scrollTicks), TimeSpan.Zero);

    public WindowEvents(Action changed, Action<bool> scrolled)
    {
        windowEvent = (_, type, window, objectID, childID, _, _) =>
        {
            if (type == 3 || (window == Native.GetForegroundWindow() && objectID == 0 && childID == 0)) changed();
        };
        keyboard = (code, message, data) =>
        {
            if (code >= 0 && message is 0x100 or 0x104)
            {
                Interlocked.Exchange(ref lastKeyTicks, DateTimeOffset.UtcNow.UtcTicks);
                if (Marshal.ReadInt32(data) is 0x20 or 0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or 0x4A or 0x4B)
                {
                    Interlocked.Exchange(ref scrollTicks, DateTimeOffset.UtcNow.UtcTicks);
                    scrolled(false);
                }
            }
            return Native.CallNextHookEx(0, code, message, data);
        };
        mouse = (code, message, data) =>
        {
            if (code >= 0 && message is 0x20A or 0x20E)
            {
                Interlocked.Exchange(ref scrollTicks, DateTimeOffset.UtcNow.UtcTicks);
                scrolled(true);
            }
            return Native.CallNextHookEx(0, code, message, data);
        };
        foregroundHook = Native.SetWinEventHook(3, 3, 0, windowEvent, 0, 0, 0);
        locationHook = Native.SetWinEventHook(0x800B, 0x800B, 0, windowEvent, 0, 0, 0);
        keyboardHook = Native.SetWindowsHookExW(13, keyboard, Native.GetModuleHandleW(null), 0);
        mouseHook = Native.SetWindowsHookExW(14, mouse, Native.GetModuleHandleW(null), 0);
        if (foregroundHook == 0 || locationHook == 0 || keyboardHook == 0 || mouseHook == 0)
        {
            var error = new Win32Exception();
            Dispose();
            throw error;
        }
    }

    public void Dispose()
    {
        if (foregroundHook != 0) Native.UnhookWinEvent(foregroundHook);
        if (locationHook != 0) Native.UnhookWinEvent(locationHook);
        if (keyboardHook != 0) Native.UnhookWindowsHookEx(keyboardHook);
        if (mouseHook != 0) Native.UnhookWindowsHookEx(mouseHook);
    }
}
