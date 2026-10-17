using System.Text.Json;

internal static class BuiltinModelBatchChecks
{
    public static async Task Run()
    {
        const string empty = "[sprite] model request k=3 lines=8 tokens≈500 prefill=5629 first=-1 total=8319 marks=1 located=0 reason=ok exclude=0 started=123\n";
        var cancelled = empty.Replace("reason=ok", "reason=cancelled");
        var positive = empty.Replace("located=0", "located=1");
        var shown = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var failed = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);

        async Task ExpectFailure(string stderr)
        {
            var pending = BuiltinModelChecks.WaitForOverlay(shown.Task, failed.Task, () => stderr);
            if (!pending.IsCompleted) throw new Exception("Completed empty/unsuccessful batch did not fail promptly");
            try { await pending; }
            catch (Exception error) when (error.Message.Contains(stderr.TrimEnd(), StringComparison.Ordinal)) { return; }
            throw new Exception("Batch failure omitted existing diagnostics");
        }
        await ExpectFailure(empty);
        await ExpectFailure(empty.Replace("marks=1", "marks=0"));
        await ExpectFailure(positive.Replace("reason=ok", "reason=timeout"));

        var log = cancelled;
        var afterCancellation = BuiltinModelChecks.WaitForOverlay(shown.Task, failed.Task, () => log);
        if (afterCancellation.IsCompleted) throw new Exception("Initial cancellation ended overlay wait");
        log += empty;
        var rejected = false;
        try { await afterCancellation.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (Exception error) when (error.Message.Contains(empty.TrimEnd(), StringComparison.Ordinal)) { rejected = true; }
        if (!rejected) throw new Exception("Empty batch after cancellation did not fail with diagnostics");

        // The completion log arrives first; only the subsequent overlay may pass.
        var afterPositive = BuiltinModelChecks.WaitForOverlay(shown.Task, failed.Task, () => cancelled + positive);
        if (afterPositive.IsCompleted) throw new Exception("Positive batch did not wait for overlay RPC");
        var narration = JsonSerializer.SerializeToElement(new { ruleID = "sprite-model" });
        shown.SetResult(narration);
        if ((await afterPositive.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("ruleID").GetString() != "sprite-model")
            throw new Exception("Overlay result was lost");

        Console.WriteLine("PASS builtin batch observation: empty/unsuccessful diagnostics, initial cancellation, positive batch before overlay RPC");
    }
}
