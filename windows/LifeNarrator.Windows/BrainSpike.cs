using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace LifeNarrator.Windows;

internal static class BrainSpike
{
    public static async Task Run()
    {
        using var process = Process.Start(new ProcessStartInfo(Path.GetFullPath("artifacts/brain/narrator-brain.exe"))
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8, UseShellExecute = false,
            WorkingDirectory = Path.GetFullPath("artifacts/brain")
        })!;
        var stderr = process.StandardError.ReadToEndAsync();
        var exchanges = new List<object>();
        async Task<JsonElement> Exchange(object request)
        {
            var json = JsonSerializer.Serialize(request);
            var timer = Stopwatch.StartNew();
            await process.StandardInput.WriteLineAsync(json);
            await process.StandardInput.FlushAsync();
            var response = await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30));
            var parsed = JsonSerializer.Deserialize<JsonElement>(response!);
            exchanges.Add(new { request, response = parsed, elapsedMs = timer.Elapsed.TotalMilliseconds });
            return parsed;
        }
        var ping = await Exchange(new { jsonrpc = "2.0", id = 1, method = "ping" });
        var match = await Exchange(new { jsonrpc = "2.0", id = 2, method = "matchRules", @params = new
        {
            snapshot = new { bundleId = "fixture", appName = "Fixture", pid = 1,
                windowFrame = new[] { new[] { 0, 0 }, new[] { 800, 600 } },
                contentFrame = new[] { new[] { 0, 0 }, new[] { 800, 600 } }, screenIndex = 0,
                textLines = new[] { new { text = "又要上班了！", rect = new[] { new[] { 40, 80 }, new[] { 300, 40 } }, role = "text" } },
                textSource = "ax", sensitiveRects = Array.Empty<int[][]>(), secureFocused = false, fullScreen = false,
                capturedAt = "2026-10-15T08:00:00Z" },
            rules = new[] { new { id = "work", kind = "topic", source = "user", enabled = true,
                label = new { zh = "上班", en = "Work" }, sentiment = "dislike", match = new { aliases = new[] { "上班" } },
                highlight = true, quips = Array.Empty<object>() } }
        } });
        process.StandardInput.Close();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
        Artifact.Write("brain.json", new { exchanges, exitCode = process.ExitCode, stderr = await stderr });
        if (!ping.GetProperty("result").GetProperty("version").GetString()!.StartsWith("0.")
            || match.GetProperty("result")[0].GetProperty("ruleId").GetString() != "work"
            || match.GetProperty("result")[0].GetProperty("lineIndex").GetInt32() != 0 || process.ExitCode != 0)
            throw new Exception("Brain round trip failed");
    }
}
