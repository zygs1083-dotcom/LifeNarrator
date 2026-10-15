using System.Net;
using System.Net.Sockets;
using LifeNarrator.Windows;

internal static class UpdateChecks
{
    static void Reject(Action action)
    {
        try { action(); }
        catch (InvalidDataException) { return; }
        throw new Exception("Invalid update metadata accepted");
    }

    public static async Task Run()
    {
        string[] ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
            "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0"];
        foreach (var (left, right) in ordered.Zip(ordered.Skip(1)))
            if (new SemanticVersion(left).CompareTo(new SemanticVersion(right)) >= 0) throw new Exception("SemVer ordering failed");
        if (new SemanticVersion("v1.2.3+build.1").CompareTo(new SemanticVersion("1.2.3+build.2")) != 0
            || new SemanticVersion("1.0.0-999999999999999999999").CompareTo(new SemanticVersion("1.0.0-1000000000000000000000")) >= 0)
            throw new Exception("SemVer build metadata or large number ordering failed");
        foreach (var invalid in new[] { "", "1.2", "1.2.3.4", "01.2.3", "1.2.-3", "1.2.3-", "1.2.3-01", "1.2.3-a..b", "1.2.3+", "1.2.3+a+b", "1.2.3-é", "1.2.3\n" })
            Reject(() => _ = new SemanticVersion(invalid));
        var release = new AppRelease(" 0.8.1\n");
        if (release.Tag != "v0.8.1" || release.AssetURL(AppRelease.Releases, "LifeNarrator-Setup.exe").AbsoluteUri !=
            "https://github.com/zygs1083-dotcom/LifeNarrator/releases/download/v0.8.1/LifeNarrator-Setup.exe") throw new Exception("Release URL failed");
        var hash = string.Concat(Enumerable.Repeat("aB", 32));
        var valid = hash + "  LifeNarrator-Setup.exe\n";
        if (ReleaseChecksums.Sha256("LifeNarrator-Setup.exe", hash + " *LifeNarrator-Setup.exe\n") != hash.ToLowerInvariant()) throw new Exception("Checksum parsing failed");
        foreach (var invalid in new[] { "", "abcd  LifeNarrator-Setup.exe", new string('g', 64) + "  LifeNarrator-Setup.exe", hash + "  other.exe", valid + valid, "broken" })
            Reject(() => ReleaseChecksums.Sha256("LifeNarrator-Setup.exe", invalid));
        if (!new Settings().AutomaticUpdates || !System.Text.Json.JsonSerializer.Deserialize<Settings>("{}", Protocol.Json)!.AutomaticUpdates)
            throw new Exception("Automatic updates must default on, including existing settings");

        var portFinder = new TcpListener(IPAddress.Loopback, 0);
        portFinder.Start(); var port = ((IPEndPoint)portFinder.LocalEndpoint).Port; portFinder.Stop();
        var root = new Uri($"http://127.0.0.1:{port}/releases/");
        using var server = new HttpListener(); server.Prefixes.Add($"http://127.0.0.1:{port}/"); server.Start();
        async Task Reply(string path, string content, int code = 200)
        {
            var request = await server.GetContextAsync();
            if (request.Request.Url!.AbsolutePath != "/releases/" + path) throw new Exception("Wrong release endpoint");
            request.Response.StatusCode = code;
            using var writer = new StreamWriter(request.Response.OutputStream);
            await writer.WriteAsync(content);
        }
        var work = Path.Combine(Path.GetTempPath(), "LifeNarrator-update-test-" + Guid.NewGuid());
        using var updater = new Updater(root, work);
        try
        {
            var reply = Reply("latest/download/version.txt", "99.0.0");
            await updater.Check(); await reply;
            if (updater.State != UpdateState.Available) throw new Exception("New release not found");
            var quit = false;
            var metadata = Reply("download/v99.0.0/checksums-windows.txt", new string('0', 64) + "  LifeNarrator-Setup.exe");
            var install = updater.Install(() => { quit = true; return Task.CompletedTask; });
            await metadata;
            var download = Reply("download/v99.0.0/LifeNarrator-Setup.exe", "tampered");
            await install; await download;
            if (quit || updater.State != UpdateState.Failed || !updater.Error!.Contains("SHA-256 mismatch")) throw new Exception("Bad installer reached shutdown");
            reply = Reply("latest/download/version.txt", AppRelease.CurrentVersion);
            await updater.Check(); await reply;
            if (updater.State != UpdateState.UpToDate) throw new Exception("Current release comparison failed");
            reply = Reply("latest/download/version.txt", "malformed");
            await updater.Check(); await reply;
            if (updater.State != UpdateState.Failed) throw new Exception("Invalid version not reported");
            reply = Reply("latest/download/version.txt", "unavailable", 503);
            await updater.Check(); await reply;
            if (updater.State != UpdateState.Failed || !updater.Error!.Contains("503")) throw new Exception("HTTP failure not reported");
            Directory.CreateDirectory(work);
            File.WriteAllText(updater.FailurePath, "{\"Message\":\"Installer exit code: 5\",\"LogPath\":\"install.log\"}");
            if (updater.PreviousFailure() != new UpdateFailure("Installer exit code: 5", "install.log")) throw new Exception("Install failure not retained");
            reply = Reply("latest/download/version.txt", "99.0.0");
            updater.Configure(true);
            await reply;
            while (updater.IsBusy) await Task.Delay(10);
            updater.Configure(false);
            if (updater.State != UpdateState.Available) throw new Exception("Automatic startup check failed");
            if (OperatingSystem.IsWindows())
            {
                var messages = new List<string>();
                UpdateSignature.Check(Environment.ProcessPath!, Environment.ProcessPath!, messages.Add);
                if (!messages.Single().Contains("unsigned")) throw new Exception("Unsigned installer skip not logged");
                var signed = File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell/v1.0/powershell.exe"));
                signed[0x200] ^= 1;
                var tampered = Path.Combine(work, "tampered.exe");
                File.WriteAllBytes(tampered, signed);
                Reject(() => UpdateSignature.Check(tampered, Environment.ProcessPath!, _ => { }));
            }
        }
        finally { if (Directory.Exists(work)) Directory.Delete(work, true); }
        Console.WriteLine("PASS: Mac-compatible SemVer/checksums; direct release URLs; HTTP failures; hash mismatch blocks shutdown; persistent install failure");
    }
}
