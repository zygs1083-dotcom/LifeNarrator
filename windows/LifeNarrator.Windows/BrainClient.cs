using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace LifeNarrator.Windows;

internal sealed class BrainClient : IAsyncDisposable
{
    readonly Process process;
    readonly SemaphoreSlim writer = new(1);
    readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    readonly Queue<string> tail = new();
    readonly Func<string, JsonElement, Task<object?>> port;
    readonly Action<string> failed;
    readonly Task completion;
    long nextID;
    volatile bool stopping;
    volatile Exception? failure;
    internal int ProcessID => process.Id;

    public BrainClient(string executable, string logPath, Func<string, JsonElement, Task<object?>> port,
        Action<string> failed)
    {
        this.port = port;
        this.failed = failed;
        var start = new ProcessStartInfo(executable)
        {
            WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(executable))!,
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        process = Process.Start(start)!;
        completion = Task.Run(() => Monitor(logPath));
    }

    public async Task<JsonElement> Call(string method, object parameters)
    {
        var id = Interlocked.Increment(ref nextID);
        var source = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = source;
        try
        {
            if (failure != null) throw failure;
            await Write(new { jsonrpc = "2.0", id, method, @params = parameters });
            return await source.Task;
        }
        finally { pending.TryRemove(id, out _); }
    }

    async Task Write(object message)
    {
        var line = JsonSerializer.Serialize(message, Protocol.Json);
        await writer.WaitAsync();
        try { await process.StandardInput.WriteLineAsync(line); await process.StandardInput.FlushAsync(); }
        finally { writer.Release(); }
    }

    async Task Read()
    {
        while (await process.StandardOutput.ReadLineAsync() is { } line)
        {
            var message = JsonSerializer.Deserialize<JsonElement>(line);
            if (message.GetProperty("jsonrpc").GetString() != "2.0") throw new InvalidDataException("Invalid brain JSON-RPC version");
            if (message.TryGetProperty("method", out var method))
            {
                // Dispatch without waiting: overlay.show may call layout on this same connection.
                _ = Reply(message, method.GetString()!);
            }
            else
            {
                var id = message.GetProperty("id").GetInt64();
                if (!pending.TryGetValue(id, out var source)) continue;
                if (message.TryGetProperty("error", out var error)) source.TrySetException(new BrainException(error));
                else source.TrySetResult(message.GetProperty("result"));
            }
        }
    }

    async Task Reply(JsonElement message, string method)
    {
        try
        {
            object response;
            try
            {
                var result = await port(method, message.TryGetProperty("params", out var p) ? p :
                    JsonSerializer.SerializeToElement(new { }));
                if (!message.TryGetProperty("id", out var id)) return;
                response = new { jsonrpc = "2.0", id, result };
            }
            catch (Exception error)
            {
                if (!message.TryGetProperty("id", out var id)) throw;
                response = new { jsonrpc = "2.0", id,
                    error = new { code = error is WindowUnavailableException ? -32005 : error is MissingMethodException ? -32601 : -32000, message = error.Message } };
            }
            await Write(response);
        }
        catch (Exception error) { Abort(error); }
    }

    async Task Stderr(string logPath)
    {
        using var log = new StreamWriter(logPath, append: true, Encoding.UTF8) { AutoFlush = true };
        while (await process.StandardError.ReadLineAsync() is { } line)
        {
            tail.Enqueue(line);
            if (tail.Count > 6) tail.Dequeue();
            await log.WriteLineAsync(line);
        }
    }

    void Abort(Exception error)
    {
        failure = error;
        foreach (var source in pending.Values) source.TrySetException(error);
        if (!process.HasExited) process.Kill(entireProcessTree: true);
    }

    async Task Monitor(string logPath)
    {
        var stderr = Stderr(logPath);
        try
        {
            await Read();
            if (!stopping) Abort(new EndOfStreamException("Brain stdout closed unexpectedly"));
        }
        catch (Exception error) { Abort(error); }
        await process.WaitForExitAsync();
        await stderr;
        var reason = failure ?? new EndOfStreamException($"Brain exited ({process.ExitCode})");
        failure = reason;
        foreach (var source in pending.Values) source.TrySetException(reason);
        if (!stopping) failed($"{reason.Message}\n{string.Join('\n', tail)}");
    }

    public async ValueTask DisposeAsync()
    {
        stopping = true;
        await writer.WaitAsync();
        try { process.StandardInput.Close(); }
        finally { writer.Release(); }
        if (await Task.WhenAny(completion, Task.Delay(TimeSpan.FromSeconds(5))) != completion)
            process.Kill(entireProcessTree: true);
        await completion;
        process.Dispose();
    }
}

internal sealed class BrainException(JsonElement error) : Exception(error.GetProperty("message").GetString());

internal sealed class WindowUnavailableException() : Exception("Window unavailable");
