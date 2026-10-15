using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.VisualTree;

namespace LifeNarrator.Windows;

public sealed partial class ShellApp
{
    async Task VerifyUpdate()
    {
        try
        {
            ShowSettings(); settingsWindow!.SelectTab(2);
            verificationScreen = settingsWindow.Screens.Primary!.Bounds;
            settingsWindow.UpdateLayout();
            var check = settingsWindow.GetVisualDescendants().OfType<Button>()
                .Single(b => AutomationProperties.GetAutomationId(b) == "updates-check");
            check.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            while (updater.IsBusy) await Task.Delay(50);
            if (updater.State != UpdateState.Available || !updateItem.IsVisible)
                throw new Exception("Update not available: " + updater.Error);
            settingsWindow.UpdateLayout();
            settingsWindow.GetVisualDescendants().OfType<ScrollViewer>().First().ScrollToEnd();
            await Capture("update-before");
            File.Copy(Settings.FilePath, Artifact.PathFor("update-settings-before.json"));
            Artifact.Write("update-before.json", new { version = AppRelease.CurrentVersion, target = updater.Release!.Tag,
                executable = Environment.ProcessPath, shellPID = Environment.ProcessId,
                brainPID = brain!.ProcessID });
            await updater.Install(Quit);
            if (updater.State == UpdateState.Failed) throw new Exception(updater.Error);
        }
        catch (Exception failure)
        {
            Artifact.Write("update-failure.json", new { error = failure.ToString() });
            await QuitWithFailure();
        }
    }

    async Task VerifyUpdateResult()
    {
        try
        {
            ShowSettings(); settingsWindow!.SelectTab(2);
            verificationScreen = settingsWindow.Screens.Primary!.Bounds;
            settingsWindow.UpdateLayout();
            settingsWindow.GetVisualDescendants().OfType<ScrollViewer>().First().ScrollToEnd();
            await Capture("update-after");
            var ping = await brain!.Call("ping", new { });
            File.Copy(Settings.FilePath, Artifact.PathFor("update-settings-after.json"));
            Artifact.Write("update-after.json", new { version = AppRelease.CurrentVersion, executable = Environment.ProcessPath,
                shellPID = Environment.ProcessId, brain = ping, dataDirectory = Settings.DataDirectory,
                installFailure = updateFailure });
            await Quit();
        }
        catch (Exception failure)
        {
            Artifact.Write("update-failure.json", new { error = failure.ToString() });
            await QuitWithFailure();
        }
    }

    async Task QuitWithFailure()
    {
        exiting = true; await Stop(); updater.Dispose(); tray.Dispose(); desktop.Shutdown(1);
    }
}
