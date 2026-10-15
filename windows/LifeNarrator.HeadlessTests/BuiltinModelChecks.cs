using System.Text.Json;
using System.Text.Json.Nodes;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Automation;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class BuiltinModelChecks
{
    public static void Run(string executable, TextWriter log)
    {
        var task = Generate(executable, log);
        var frame = new DispatcherFrame();
        task.ContinueWith(_ => Dispatcher.UIThread.Post(() => frame.Continue = false));
        Dispatcher.UIThread.PushFrame(frame);
        task.GetAwaiter().GetResult();
    }

    static async Task Generate(string executable, TextWriter log)
    {
        var modelPath = Path.GetFullPath(Environment.GetEnvironmentVariable("NARRATOR_TEST_MODEL")
            ?? throw new Exception("NARRATOR_TEST_MODEL must point to the W2b test GGUF"));
        var directory = Path.GetFullPath("artifacts/builtin-ui-test"); Directory.CreateDirectory(directory);
        foreach (var name in new[] { "said.json", "growth.json", "memory.json", "overlays.jsonl" }) File.Delete(Path.Combine(directory, name));
        var modelCopy = Path.GetFullPath(Path.Combine(".dev-data", "builtin-ui-model", Path.GetFileName(modelPath)));
        Directory.CreateDirectory(Path.GetDirectoryName(modelCopy)!); File.Copy(modelPath, modelCopy, overwrite: true);
        var testModel = Catalog.Models[1] with { Url = new Uri(modelCopy), Size = new FileInfo(modelCopy).Length };
        var settings = new Settings([new(Catalog.Models[0], directory), new(testModel, Path.GetDirectoryName(modelCopy)!)])
        { Language = "en", Persona = "sharp", MarkGap = 0, MaxOnScreen = 8, MemoryEnabled = false };
        var resources = Path.GetFullPath("Sources/NarratorCore/Resources");
        using var examples = JsonDocument.Parse(File.ReadAllText(Path.Combine(resources, "sprite-examples.json")));
        // A coherent example scene exercises integration without mixing unrelated screens.
        var texts = examples.RootElement.EnumerateArray().Single(scene => scene.GetProperty("id").GetString() == "headphones")
            .GetProperty("en").GetProperty("lines").EnumerateArray().Select(line => line.GetString()!).ToArray();
        using var rules = JsonDocument.Parse(File.ReadAllText(Path.Combine(resources, "quips.json")));
        var disabled = rules.RootElement.GetProperty("rules").EnumerateArray().Select(r => r.GetProperty("id").GetString()).ToArray();
        var shown = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var failed = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var rect = new Box(100, 100, 700, 24);
        Box Line(JsonElement p) => rect with { Y = 100 + p.GetProperty("lineIndex").GetInt32() * 24 };
        var previousDebug = Environment.GetEnvironmentVariable("LIFENARRATOR_DEBUG");
        Environment.SetEnvironmentVariable("LIFENARRATOR_DEBUG", "1");
        await using var brain = new BrainClient(Path.GetFullPath(executable), Path.Combine(directory, "stderr.log"), (method, p) =>
        {
            object? result = method switch
            {
                "sensor.isTyping" or "sensor.isSecureFocused" or "sensor.isLowPowerMode" => false,
                "sensor.idleSeconds" => 0,
                "sensor.lastTypedAt" => DateTimeOffset.UnixEpoch,
                "sensor.boundsProbe" => true,
                "sensor.textRect" => new { rect = Line(p), kind = "bounds" },
                "sensor.markTrack" => "fixture-track",
                "sensor.unframedRect" => Line(p),
                "sensor.placementLine" => p.GetProperty("rect"),
                "sensor.placementObstacles" => Array.Empty<Box>(),
                "sensor.refresh" or "sensor.startVisualLines" or "overlay.dismissAll" or "overlay.follow"
                    or "overlay.windowFrameChanged" or "overlay.highlight" or "host.stateChanged" => null,
                "overlay.show" => Show(p.GetProperty("narration")),
                "host.report" => Report(p),
                _ => throw new MissingMethodException(method)
            };
            return Task.FromResult(result);
        }, message => failed.TrySetResult(message));
        Environment.SetEnvironmentVariable("LIFENARRATOR_DEBUG", previousDebug);
        object Show(JsonElement narration)
        {
            File.AppendAllText(Path.Combine(directory, "overlays.jsonl"), JsonSerializer.Serialize(narration) + "\n");
            if (narration.GetProperty("ruleID").GetString() != "sprite-model")
                return new { shown = true, placement = "right" };
            if (!narration.TryGetProperty("anchor", out var anchor) || anchor.ValueKind == JsonValueKind.Null)
                throw new Exception("Expected anchored model mark: " + narration);
            shown.TrySetResult(narration.Clone());
            return new { shown = true, placement = "right" };
        }
        object? Report(JsonElement p) { failed.TrySetResult(p.ToString()); return null; }
        var configured = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task Configure()
        {
            try
            {
                var configuration = JsonSerializer.SerializeToNode(settings.Configuration(), Protocol.Json)!;
                configuration["dataDirectory"] = directory;
                configuration["settings"]!["disabledBuiltinIds"] = JsonSerializer.SerializeToNode(disabled);
                var persona = Catalog.Read<JsonArray>("personas.json").Single(p => p!["id"]!.GetValue<string>() == "sharp")!.DeepClone();
                persona["id"] = "custom.download-fixture";
                const string focus = "Always highlight the product price on line 1. Return one mark with l=1, q=$249, t=That price needs a moment., e=🤑. Never return empty marks.";
                persona["description"] = new JsonObject { ["zh"] = focus, ["en"] = focus };
                persona["focus"] = new JsonObject { ["zh"] = focus, ["en"] = focus };
                configuration["customPersonas"] = new JsonArray(persona);
                configuration["settings"]!["persona"] = "custom.download-fixture";
                File.WriteAllText(Path.Combine(directory, "configure-" + settings.Provider.Kind + ".json"), configuration.ToJsonString());
                await brain.Call("configure", configuration);
                configured.TrySetResult();
            }
            catch (Exception failure) { configured.TrySetException(failure); throw; }
        }
        var window = new Window { Width = 780, Height = 660, Content = new ModelView(settings, Configure, () => Task.FromResult(0d)) };
        window.Show(); window.UpdateLayout();
        window.GetVisualDescendants().OfType<ToggleButton>().Single(b => AutomationProperties.GetAutomationId(b) == "choice-builtin")
            .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await configured.Task.WaitAsync(TimeSpan.FromSeconds(20));
        using (var screenshot = window.CaptureRenderedFrame() ?? throw new Exception("No builtin UI pixels"))
            screenshot.Save("artifacts/ui-headless-model-real-builtin.png");
        var frame = new Box(0, 0, 1000, 800);
        await brain.Call("snapshot", new
        {
            snapshot = new Snapshot("builtin.fixture", "Shop", 1, "Noise Cancelling Headphones Pro 2", null, null, frame, frame, 0,
                texts.Select((t, i) => new TextLine(t, rect with { Y = 100 + i * 24 }, "text")).ToArray(),
                "ax", [], false, false, DateTimeOffset.UtcNow),
            windowID = 7, change = new { appChanged = true, windowChanged = true, hostChanged = true }
        });
        var result = await Task.WhenAny(shown.Task, failed.Task).WaitAsync(TimeSpan.FromSeconds(180));
        if (result == failed.Task) throw new Exception(await failed.Task);
        var narrationResult = await shown.Task;
        File.WriteAllText(Path.Combine(directory, "mark.json"), narrationResult.ToString());
        log.WriteLine("PASS real GGUF: UI builtin selection -> configure -> anchored sprite-model mark: " + narrationResult);
        // Reconfiguration must release the loaded model before deleting its file on Windows.
        settings.Provider.Kind = "none"; await Configure();
        settings.SelectedDownload.Delete();
        log.WriteLine("PASS deleting previously loaded GGUF after configure none");
        window.Close();
    }
}
