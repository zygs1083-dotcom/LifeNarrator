using System.Text.Json;

internal static class BuiltinModelBatchChecks
{
    public static async Task Run()
    {
        const string empty = "[sprite] model request k=3 lines=8 tokens≈500 prefill=5629 first=-1 total=8319 marks=1 located=0 reason=ok exclude=0 started=123\n";
        const string rejection = "[sprite] model mark rejected reason=emoji l=1\n";
        var cancelled = empty.Replace("reason=ok", "reason=cancelled");
        var positive = empty.Replace("located=0", "located=1");
        var shown = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var failed = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var retries = new List<int>();
        using var output = new StringWriter();
        var log = rejection + empty;
        var thirdBatch = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task Retry(int batch)
        {
            retries.Add(batch);
            if (batch == 3) thirdBatch.TrySetResult();
            return Task.CompletedTask;
        }

        var pending = BuiltinModelChecks.WaitForOverlay(shown.Task, failed.Task, () => log, Retry, output);
        if (!retries.SequenceEqual(new[] { 2 })) throw new Exception("Empty batch did not request batch 2");
        // Re-reading the same log must not spend another attempt.
        await Task.Delay(250);
        if (pending.IsCompleted || retries.Count != 1) throw new Exception("An old log line triggered another retry");
        log += rejection + empty;
        await thirdBatch.Task.WaitAsync(TimeSpan.FromSeconds(5));
        log += rejection + empty;
        try
        {
            await pending.WaitAsync(TimeSpan.FromSeconds(5));
            throw new Exception("Three empty batches passed");
        }
        catch (Exception error) when (error.Message.Contains("3 batches", StringComparison.Ordinal))
        {
            if (error.Message.Split(empty.TrimEnd()).Length != 4 || error.Message.Split(rejection.TrimEnd()).Length != 4)
                throw new Exception("Failure omitted batch/rejection diagnostics", error);
        }
        if (!retries.SequenceEqual(new[] { 2, 3 }) || !output.ToString().Contains("RETRY builtin batch 3/3"))
            throw new Exception("Retries were not bounded and visible");

        retries.Clear();
        log = positive.Replace("reason=ok", "reason=error");
        try
        {
            await BuiltinModelChecks.WaitForOverlay(shown.Task, failed.Task, () => log, Retry, output);
            throw new Exception("An error batch passed");
        }
        catch (Exception error) when (error.Message.Contains(log.TrimEnd(), StringComparison.Ordinal)) { }
        if (retries.Count != 0) throw new Exception("An error batch retried");

        log = cancelled;
        var afterCancellation = BuiltinModelChecks.WaitForOverlay(shown.Task, failed.Task, () => log, Retry, output);
        await Task.Delay(150);
        if (afterCancellation.IsCompleted || retries.Count != 0) throw new Exception("Cancellation retried or ended overlay wait");
        log += positive;
        await Task.Delay(150);
        if (afterCancellation.IsCompleted || retries.Count != 0) throw new Exception("Positive batch did not wait for overlay RPC");
        shown.SetResult(JsonSerializer.SerializeToElement(new { ruleID = "sprite-model" }));
        if ((await afterCancellation.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("ruleID").GetString() != "sprite-model")
            throw new Exception("Overlay result was lost");

        Console.WriteLine("PASS builtin batches: new log lines only, three-batch limit, error/cancelled do not retry");
    }
}
