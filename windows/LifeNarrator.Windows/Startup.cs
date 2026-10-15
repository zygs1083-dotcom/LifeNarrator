using Microsoft.Win32;

namespace LifeNarrator.Windows;

internal static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue("LifeNarrator", '"' + Environment.ProcessPath! + '"');
        else key.DeleteValue("LifeNarrator", throwOnMissingValue: false);
    }
}
