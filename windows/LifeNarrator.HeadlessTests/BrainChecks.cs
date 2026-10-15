using System.Text.Json;
using LifeNarrator.Windows;

internal static class BrainChecks
{
    public static async Task Run(string executable)
    {
        var directory = Path.GetFullPath("artifacts/brain-client-test");
        Directory.CreateDirectory(directory);
        File.Delete(Path.Combine(directory, "said.json"));
        var shown = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var failure = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        BrainClient brain = null!;
        var geometry = new WindowGeometry(new Box(0, 0, 1000, 800), 60);
        var configure = new
        {
            settings = new { liveliness = "quiet", markGap = 0, paused = false, blacklist = Array.Empty<string>(),
                persona = "gentle", lang = "zh", disabledBuiltinIds = Array.Empty<string>(), maxOnScreen = 3, ownProcessID = 0, memoryEnabled = true },
            rules = new[] { new { id = "work", kind = "topic", source = "user", enabled = true,
                label = new { zh = "上班", en = "work" }, sentiment = "neutral", match = new { aliases = new[] { "上班" } },
                highlight = true, quips = new[] { new { lang = "zh", persona = "gentle", text = "辛苦啦，慢慢来", emoji = new[] { "😺" } } } } },
            customPersonas = Array.Empty<object>(), generator = new { kind = "none" }, dataDirectory = directory
        };
        brain = new BrainClient(Path.GetFullPath(executable), Path.Combine(directory, "stderr.log"), async (method, p) =>
        {
            switch (method)
            {
                case "sensor.isTyping": case "sensor.isSecureFocused": case "sensor.isLowPowerMode": return false;
                case "sensor.idleSeconds": return 0;
                case "sensor.lastTypedAt": return DateTimeOffset.UnixEpoch;
                case "sensor.refresh": case "sensor.startVisualLines": case "sensor.markTrack":
                case "overlay.dismissAll": case "overlay.follow": case "overlay.windowFrameChanged": return null;
                case "sensor.boundsProbe": return true;
                case "sensor.textRect": return new { rect = new Box(120, 200, 80, 24), kind = "bounds" };
                case "sensor.unframedRect": case "sensor.placementLine": return new Box(100, 200, 300, 24);
                case "sensor.placementObstacles": return Array.Empty<Box>();
                case "overlay.highlight": return null;
                case "overlay.show":
                    var narration = p.GetProperty("narration").Read<Narration>();
                    var tier = await brain.Call("layout.sizeTier", new { requested = "medium", window = narration.Window });
                    if (tier.GetString() != "medium") throw new Exception("Wrong size tier");
                    var placement = await brain.Call("layout.place", new
                    {
                        size = new Dimensions(180, 44), narration.Anchor, narration.Line, narration.Window,
                        visibleFrame = geometry.Frame, occupied = Array.Empty<Box>(), obstacles = Array.Empty<Box>(),
                        inkInset = new Dimensions(0, 0), stackSizes = Array.Empty<Dimensions>()
                    });
                    if (placement.GetProperty("highlight").Read<Box>().W <= 0) throw new Exception("Missing highlight");
                    shown.TrySetResult();
                    return new { shown = true, placement = placement.GetProperty("placement").GetString() };
                case "host.report": throw new Exception(p.ToString());
                default: throw new MissingMethodException(method);
            }
        }, message => failure.TrySetResult(message));
        await using (brain)
        {
            await brain.Call("configure", configure).WaitAsync(TimeSpan.FromSeconds(10));
            var snapshot = new Snapshot("fixture", "Fixture", 42, "Work", null, null, geometry.Frame,
                new Box(0, 60, 1000, 740), 0, [new TextLine("今天又要上班了", new Box(100, 200, 300, 24), "text")],
                "ax", [], false, false, DateTimeOffset.UtcNow);
            await brain.Call("snapshot", new { snapshot, windowID = 1, change = new { appChanged = true, windowChanged = true, hostChanged = true } });
            var pings = Enumerable.Range(0, 8).Select(_ => brain.Call("ping", new { })).ToArray();
            await Task.WhenAll(pings).WaitAsync(TimeSpan.FromSeconds(10));
            if (pings.Any(x => !x.Result.GetProperty("version").GetString()!.StartsWith("0."))) throw new Exception("Ping pairing failed");
            await shown.Task.WaitAsync(TimeSpan.FromSeconds(15));
            try { await brain.Call("unknown", new { }); throw new Exception("Expected RPC error"); }
            catch (BrainException) { }
        }
        if (failure.Task.IsCompleted) throw new Exception(await failure.Task);
        Console.WriteLine("PASS: real brain configure/snapshot, concurrent requests, nested layout during overlay.show, EOF shutdown");
        var crashed = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var broken = new BrainClient(Path.GetFullPath(executable), Path.Combine(directory, "failure.log"),
            (method, _) => Task.FromResult<object?>(method == "sensor.isLowPowerMode" ? "invalid-boolean" : null),
            message => crashed.TrySetResult(message));
        await broken.Call("configure", configure);
        await broken.Call("snapshot", new
        {
            snapshot = new Snapshot("fixture", "Fixture", 42, "Work", null, null, geometry.Frame,
                new Box(0, 60, 1000, 740), 0, [], "none", [], false, false, DateTimeOffset.UtcNow),
            windowID = 2, change = new { appChanged = true, windowChanged = true, hostChanged = true }
        });
        var crash = await crashed.Task.WaitAsync(TimeSpan.FromSeconds(10));
        if (!crash.Contains(File.ReadLines(Path.Combine(directory, "failure.log")).Last()))
            throw new Exception("Missing brain stderr in failure report: " + crash);
        try { await broken.Call("ping", new { }); throw new Exception("Dead brain accepted ping"); }
        catch (EndOfStreamException) { }
        Console.WriteLine("PASS: unexpected brain exit surfaces stderr, rejects new calls, and is not retried");
    }
}
