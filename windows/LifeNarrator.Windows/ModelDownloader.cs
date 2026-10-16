using System.Net;
using System.Diagnostics;
using Avalonia.Threading;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace LifeNarrator.Windows;

internal sealed record DownloadableModel(string Name, Uri Url, long Size, string Sha256)
{
    public string Filename => Path.GetFileName(Url.AbsolutePath);
    public Uri FromSource(string host) => new UriBuilder(Url) { Host = host }.Uri;
}

internal enum ModelDownloadState { NotDownloaded, Downloading, Verifying, Ready }

internal sealed class ModelDownloader
{
    static readonly HttpClient client = new() { Timeout = Timeout.InfiniteTimeSpan };
    public DownloadableModel Model { get; }
    public string Destination { get; }
    public string PartialPath => Destination + ".download";
    public ModelDownloadState State { get; private set; }
    public double Progress { get; private set; }
    public string? Error { get; private set; }
    public string Source { get; set; } = "huggingface.co";
    public bool HasPartial { get; private set; }
    public event Action? Changed;
    CancellationTokenSource? cancellation;
    Task? running;

    public ModelDownloader(DownloadableModel model, string directory)
    {
        Model = model;
        Destination = Path.Combine(directory, model.Filename);
        HasPartial = File.Exists(PartialPath);
        State = File.Exists(Destination) ? ModelDownloadState.Ready : ModelDownloadState.NotDownloaded;
    }

    public Task Start(Uri url)
    {
        cancellation = new CancellationTokenSource();
        var token = cancellation.Token;
        running = Task.Run(() => Download(url, token));
        return running;
    }

    public async Task Pause()
    {
        cancellation!.Cancel();
        await running!;
    }

    public void Delete()
    {
        File.Delete(Destination);
        File.Delete(PartialPath);
        HasPartial = false; Error = null; Progress = 0;
        SetState(ModelDownloadState.NotDownloaded);
    }

    async Task Download(Uri url, CancellationToken token)
    {
        Error = null;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Destination)!);
            var offset = HasPartial ? new FileInfo(PartialPath).Length : 0;
            Progress = (double)offset / Model.Size;
            SetState(ModelDownloadState.Downloading);
            if (offset < Model.Size)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
                response.EnsureSuccessStatusCode();
                if (response.StatusCode == HttpStatusCode.PartialContent)
                {
                    var range = response.Content.Headers.ContentRange;
                    if (range?.From != offset || range.Length != Model.Size)
                        throw new InvalidDataException("Invalid Content-Range: " + range);
                }
                else if (response.StatusCode == HttpStatusCode.OK) offset = 0;
                else throw new InvalidDataException("Unexpected download status: " + response.StatusCode);
                await using var input = await response.Content.ReadAsStreamAsync(token);
                await using var output = new FileStream(PartialPath, offset == 0 ? FileMode.Create : FileMode.Append,
                    FileAccess.Write, FileShare.Read, 131072, useAsync: true);
                var buffer = new byte[131072];
                var notification = Stopwatch.StartNew();
                var firstProgress = true;
                int count;
                while ((count = await input.ReadAsync(buffer, token)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, count), token);
                    offset += count;
                    Progress = (double)offset / Model.Size;
                    if (firstProgress || notification.ElapsedMilliseconds >= 250)
                    { Notify(); notification.Restart(); firstProgress = false; }
                    if (offset > Model.Size)
                    {
                        await output.DisposeAsync(); File.Delete(PartialPath);
                        throw new InvalidDataException($"Size mismatch: {offset} bytes; expected {Model.Size}");
                    }
                }
            }
            token.ThrowIfCancellationRequested();
            SetState(ModelDownloadState.Verifying);
            {
                await using var file = File.OpenRead(PartialPath);
                var size = file.Length;
                var hash = Convert.ToHexString(await SHA256.HashDataAsync(file)).ToLowerInvariant();
                if (size != Model.Size || hash != Model.Sha256)
                    throw new InvalidDataException($"SHA-256 mismatch: {hash} ({size} bytes); expected {Model.Sha256} ({Model.Size} bytes)");
            }
            File.Move(PartialPath, Destination);
            SetState(ModelDownloadState.Ready);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            SetState(ModelDownloadState.NotDownloaded);
        }
        catch (Exception failure)
        {
            Error = failure.Message;
            if (State == ModelDownloadState.Verifying) File.Delete(PartialPath);
            SetState(ModelDownloadState.NotDownloaded);
            throw;
        }
        finally { HasPartial = File.Exists(PartialPath); cancellation!.Dispose(); cancellation = null; Notify(); }
    }

    void Notify() => Dispatcher.UIThread.Post(() => Changed?.Invoke());
    void SetState(ModelDownloadState state) { State = state; Notify(); }
}
