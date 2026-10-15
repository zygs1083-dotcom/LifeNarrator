using System.ComponentModel;
using System.Runtime.InteropServices;
using Avalonia.Controls;

namespace LifeNarrator.Windows;

internal sealed class ChatHotKey : IDisposable
{
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)] static extern bool UnregisterHotKey(nint window, int id);
    readonly Window window = new() { ShowInTaskbar = false, ShowActivated = false };
    readonly nint handle;

    public ChatHotKey(Action open)
    {
        Win32Properties.AddWndProcHookCallback(window, (nint hwnd, uint message, nint wParam, nint lParam, ref bool handled) =>
        {
            if (message == 0x0312 && wParam == 1) { handled = true; open(); }
            return 0;
        });
        handle = window.TryGetPlatformHandle()!.Handle;
        if (!RegisterHotKey(handle, 1, 0x0001 | 0x0004 | 0x4000, 0x20))
        { var failure = new Win32Exception(); window.Close(); throw failure; }
    }

    public void Dispose()
    {
        if (!UnregisterHotKey(handle, 1)) throw new Win32Exception();
        window.Close();
    }
}
