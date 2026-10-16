using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using Avalonia.Threading;
using LifeNarrator.Windows;

internal static class DownloadResponsivenessChecks
{
    public static void Run()
    {
        var data = new byte[32 * 1024 * 1024]; new Random(42).NextBytes(data);
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        using var server = new HttpListener(); server.Prefixes.Add($"http://127.0.0.1:{port}/"); server.Start();
        var url = new Uri($"http://127.0.0.1:{port}/fast.gguf");
        var directory = Path.GetFullPath("artifacts/download-responsiveness"); Directory.CreateDirectory(directory);
        var download = new ModelDownloader(new DownloadableModel("fast", url, data.Length, Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant()), directory);
        var notifications = 0;
        download.Changed += () =>
        { if (!Dispatcher.UIThread.CheckAccess()) throw new Exception("Download notification is not on UI thread"); notifications++; };
        var response = Task.Run(async () =>
        {
            var context = await server.GetContextAsync(); context.Response.ContentLength64 = data.Length;
            for (var offset = 0; offset < data.Length; offset += 1024 * 1024)
            {
                await context.Response.OutputStream.WriteAsync(data.AsMemory(offset, 1024 * 1024));
                await Task.Delay(5);
            }
            context.Response.Close();
        });
        var time = Stopwatch.StartNew(); var messages = 0; var worst = TimeSpan.Zero;
        var transfer = download.Start(url);
        var probe = Task.Run(async () =>
        {
            while (!transfer.IsCompleted)
            {
                var posted = Stopwatch.StartNew();
                await Dispatcher.UIThread.InvokeAsync(() => { messages++; if (posted.Elapsed > worst) worst = posted.Elapsed; });
                await Task.Delay(10);
            }
        });
        var done = Task.WhenAll(transfer, response, probe).WaitAsync(TimeSpan.FromSeconds(20));
        var frame = new DispatcherFrame(); done.ContinueWith(_ => Dispatcher.UIThread.Post(() => frame.Continue = false));
        Dispatcher.UIThread.PushFrame(frame); done.GetAwaiter().GetResult(); Dispatcher.UIThread.RunJobs();
        if (messages < 3 || worst > TimeSpan.FromMilliseconds(500) || notifications > Math.Ceiling(time.Elapsed.TotalSeconds * 4) + 6)
            throw new Exception($"Download starved UI or flooded progress: messages={messages}, worst={worst.TotalMilliseconds:0} ms, notifications={notifications}");
        File.WriteAllText(Path.Combine(directory, "result.log"), $"32 MiB local transfer; UI messages={messages}; maximum dispatch latency={worst.TotalMilliseconds:0.0} ms; notifications={notifications}; elapsed={time.Elapsed.TotalSeconds:0.00}s\n");
        download.Delete();
        Console.WriteLine($"PASS: fast 32 MiB download keeps UI responsive ({worst.TotalMilliseconds:0.0} ms); progress throttled ({notifications} notifications)");
    }
}
