using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class ModelDownloadChecks
{
    static void Wait(Task task)
    {
        task = task.WaitAsync(TimeSpan.FromSeconds(20));
        var frame = new DispatcherFrame();
        task.ContinueWith(_ => Dispatcher.UIThread.Post(() => frame.Continue = false));
        Dispatcher.UIThread.PushFrame(frame);
        task.GetAwaiter().GetResult();
    }
    static void Click(Window window, string id)
    {
        window.UpdateLayout();
        window.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == id)
            .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    }
    static void Capture(Window window, string name)
    {
        window.UpdateLayout();
        var heading = window.GetVisualDescendants().OfType<TextBlock>().LastOrDefault(t => t.Text == Catalog.Models[1].Name);
        heading?.GetVisualAncestors().OfType<Border>().First().BringIntoView();
        using var frame = window.CaptureRenderedFrame() ?? throw new Exception("No model page pixels");
        frame.Save("artifacts/ui-headless-model-" + name + ".png");
    }

    public static void Run(string? brainExecutable)
    {
        var work = Path.GetFullPath("artifacts/model-download-test");
        if (Directory.Exists(work)) Directory.Delete(work, true);
        Directory.CreateDirectory(work);
        using var log = new StreamWriter(Path.Combine(work, "download.log")) { AutoFlush = true };
        var data = new byte[2 * 1024 * 1024]; new Random(73).NextBytes(data);
        var hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        using var server = new HttpListener(); server.Prefixes.Add($"http://127.0.0.1:{port}/"); server.Start();
        var url = new Uri($"http://127.0.0.1:{port}/test.gguf");
        var models = Catalog.Models.Select(m => m with { Url = url, Size = data.Length, Sha256 = hash,
            Name = m.Name }).ToArray();
        // Separate filenames keep both cards usable with tiny deterministic fixtures.
        models[0] = models[0] with { Url = new Uri(url, "standard.gguf") };
        var downloads = models.Select(m => new ModelDownloader(m, Path.Combine(work, "Models"))).ToArray();
        var settings = new Settings(downloads) { Language = "zh" };
        if (settings.BuiltinModel != Catalog.Models[1].Name) throw new Exception("Windows must recommend Fast");
        var configurations = new List<JsonElement>();
        Task Configure() { configurations.Add(JsonSerializer.SerializeToElement(settings.Configuration(), Protocol.Json)); return Task.CompletedTask; }
        using var updater = new Updater();
        var window = new SettingsWindow(settings, Configure, () => Task.FromResult(0d), updater, () => Task.CompletedTask);
        window.Show(); window.SelectTab(1); Click(window, "choice-builtin");
        if (settings.Provider.Kind != "builtin" || configurations.Last().GetProperty("generator").GetProperty("kind").GetString() != "none")
            throw new Exception("Unavailable builtin must keep offline rules active");
        Capture(window, "not-downloaded");
        var download = settings.SelectedDownload;
        var request = server.GetContextAsync();
        var transfer = download.Start(url);
        Wait(request); var response = request.Result.Response;
        response.ContentLength64 = data.Length;
        Wait(response.OutputStream.WriteAsync(data.AsMemory(0, data.Length / 4)).AsTask());
        var progressed = new TaskCompletionSource();
        void OnProgress() { if (download.Progress > 0) progressed.TrySetResult(); }
        download.Changed += OnProgress; OnProgress(); Wait(progressed.Task);
        Capture(window, "downloading");
        // Detaching the model page must not stop its download or lose progress.
        window.SelectTab(0); window.SelectTab(1);
        Wait(download.Pause()); Wait(transfer); response.Abort(); download.Changed -= OnProgress;
        var partialSize = new FileInfo(download.PartialPath).Length;
        if (partialSize <= 0 || partialSize >= data.Length || File.Exists(download.Destination)) throw new Exception("Pause lost partial data");
        Capture(window, "paused");
        log.WriteLine($"PAUSE retained {partialSize} bytes; no ready file");
        var reopened = new ModelDownloader(download.Model, Path.Combine(work, "Models"));
        var ranges = new List<string?>();
        async Task Reply(byte[] bytes, bool ignoreRange = false)
        {
            var context = await server.GetContextAsync();
            var range = context.Request.Headers["Range"]; ranges.Add(range);
            var offset = range == null || ignoreRange ? 0 : int.Parse(range[6..^1]);
            log.WriteLine($"GET {context.Request.RawUrl} Range={range ?? "none"} offset={offset}");
            if (offset > 0)
            {
                context.Response.StatusCode = 206;
                context.Response.Headers["Content-Range"] = $"bytes {offset}-{bytes.Length - 1}/{bytes.Length}";
            }
            context.Response.ContentLength64 = bytes.Length - offset;
            await context.Response.OutputStream.WriteAsync(bytes.AsMemory(offset));
            context.Response.Close();
        }
        // A newly created downloader resumes the same on-disk partial after app restart.
        var reply = Reply(data);
        Wait(reopened.Start(url)); Wait(reply);
        if (ranges.Last() != $"bytes={partialSize}-" || reopened.State != ModelDownloadState.Ready || !File.ReadAllBytes(reopened.Destination).SequenceEqual(data)) throw new Exception("Range resume corrupted output");
        log.WriteLine("PASS restart + HTTP 206 resume + size/SHA-256 verification");
        reopened.Delete();
        // A server ignoring Range must replace the partial, rather than append a second copy.
        File.WriteAllBytes(download.PartialPath, data[..4096]);
        var verifying = false;
        void SnapshotVerification()
        {
            if (download.State != ModelDownloadState.Verifying) return;
            verifying = true; Capture(window, "verifying");
        }
        download.Changed += SnapshotVerification;
        reply = Reply(data, ignoreRange: true); Wait(download.Start(url)); Wait(reply);
        download.Changed -= SnapshotVerification;
        if (ranges.Last() != "bytes=4096-" || !verifying || download.State != ModelDownloadState.Ready) throw new Exception("Verification state missing");
        Click(window, "choice-" + download.Model.Name);
        var generator = configurations.Last().GetProperty("generator");
        if (generator.GetProperty("kind").GetString() != "builtin" || generator.GetProperty("modelPath").GetString() != download.Destination)
            throw new Exception("UI selection did not configure ready builtin path");
        foreach (var theme in new[] { ThemeVariant.Light, ThemeVariant.Dark })
        { Application.Current!.RequestedThemeVariant = theme; Capture(window, "ready-" + theme); }
        Click(window, "delete-" + download.Model.Name);
        if (File.Exists(download.Destination) || configurations[^2].GetProperty("generator").GetProperty("kind").GetString() != "none")
            throw new Exception("Delete did not release selected model first");
        log.WriteLine("PASS HTTP 200 replaces partial; ready UI -> builtin configure; release before delete");
        var corrupt = data.ToArray(); corrupt[0] ^= 0xff;
        reply = Reply(corrupt);
        try { Wait(download.Start(url)); throw new Exception("Corrupt model accepted"); }
        catch (InvalidDataException failure)
        {
            if (download.Error != failure.Message || !failure.Message.Contains("SHA-256 mismatch")) throw;
            log.WriteLine("PASS rejected corrupt model: " + failure.Message);
        }
        Wait(reply);
        if (download.State != ModelDownloadState.NotDownloaded || File.Exists(download.Destination) || download.HasPartial)
            throw new Exception("Corrupt file became usable or cannot be redownloaded");
        Capture(window, "checksum-error");
        var shortReply = Reply(data[..4096]);
        try { Wait(download.Start(url)); throw new Exception("Wrong model size accepted"); }
        catch (InvalidDataException failure)
        {
            if (!failure.Message.Contains("4096 bytes")) throw;
            log.WriteLine("PASS rejected size mismatch: " + failure.Message);
        }
        Wait(shortReply);
        async Task Unavailable()
        {
            var context = await server.GetContextAsync();
            context.Response.StatusCode = 503; context.Response.Close();
        }
        reply = Unavailable();
        try { Wait(download.Start(url)); throw new Exception("HTTP error accepted"); }
        catch (HttpRequestException failure)
        {
            if (download.Error != failure.Message || !failure.Message.Contains("503")) throw;
            log.WriteLine("PASS HTTP error unchanged: " + failure.Message);
        }
        Wait(reply);
        window.Close();

        var wizard = new OnboardingWindow(settings, Configure, () => Task.FromResult(0d), () => { });
        wizard.Show(); Wait(wizard.Advance()); Click(wizard, "choice-builtin"); Wait(wizard.Advance());
        Capture(wizard, "onboarding");
        // Exercise the actual download button in onboarding and its completion configure callback.
        reply = Reply(data);
        var ready = new TaskCompletionSource();
        void Ready() { if (download.State == ModelDownloadState.Ready) ready.TrySetResult(); }
        download.Changed += Ready;
        download.Source = url.Host;
        Click(wizard, "download-" + download.Model.Name); Wait(ready.Task); Wait(reply);
        Dispatcher.UIThread.RunJobs(); download.Changed -= Ready;
        if (configurations.Last().GetProperty("generator").GetProperty("kind").GetString() != "builtin")
            throw new Exception("Onboarding download did not activate builtin");
        log.WriteLine("PASS onboarding selects builtin, downloads and configures on completion");
        wizard.Close();
        if (brainExecutable != null) BuiltinModelChecks.Run(brainExecutable, log);
        Console.WriteLine("PASS: model pause/restart/Range, ignored Range, SHA-256 error, builtin selection/deletion/onboarding; artifacts/model-download-test/download.log");
    }
}
