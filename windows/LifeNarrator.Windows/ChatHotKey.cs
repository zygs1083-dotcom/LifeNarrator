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
    readonly List<int> registered = [];
    readonly Settings settings;
    readonly Action[] actions;
    HotKey?[]? current;

    public ChatHotKey(Settings settings, Action pause, Action chat, Action input)
    {
        this.settings = settings; actions = [pause, chat, input];
        Win32Properties.AddWndProcHookCallback(window, (nint hwnd, uint message, nint wParam, nint lParam, ref bool handled) =>
        {
            if (message == 0x0312 && wParam is >= 1 and <= 3) { handled = true; actions[(int)wParam - 1](); }
            return 0;
        });
        handle = window.TryGetPlatformHandle()!.Handle;
        try { Configure(); } catch { Dispose(); throw; }
    }
    public void Configure(bool suspended = false)
    {
        var shortcuts = suspended ? new HotKey?[3] : new[] { settings.PauseShortcut, settings.ChatShortcut, settings.InputShortcut };
        if (current != null && current.SequenceEqual(shortcuts)) return;
        current = null;
        foreach (var id in registered) if (!UnregisterHotKey(handle, id)) throw new Win32Exception();
        registered.Clear();
        for (var i = 0; i < shortcuts.Length; i++)
        {
            if (shortcuts[i] is not { } shortcut) continue;
            if (!RegisterHotKey(handle, i + 1, shortcut.Modifiers | 0x4000, shortcut.Key)) throw new Win32Exception();
            registered.Add(i + 1);
        }
        current = shortcuts;
    }
    public void Dispose()
    {
        foreach (var id in registered) if (!UnregisterHotKey(handle, id)) throw new Win32Exception();
        registered.Clear(); window.Close();
    }
}
