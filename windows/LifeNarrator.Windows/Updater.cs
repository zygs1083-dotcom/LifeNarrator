using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LifeNarrator.Windows;

internal enum UpdateState { Idle, Checking, UpToDate, Available, Downloading, Failed }
internal sealed record UpdateFailure(string Message, string LogPath);

internal sealed class Updater : IDisposable
{
    readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(30) };
    readonly Uri releases;
    readonly string directory;
    CancellationTokenSource? schedule;
    public UpdateState State { get; private set; }
    public AppRelease? Release { get; private set; }
    public string? Error { get; private set; }
    public int Progress { get; private set; }
    public bool IsBusy => State is UpdateState.Checking or UpdateState.Downloading;
    public event Action? Changed;
    public string FailurePath => Path.Combine(directory, "failure.json");

    public Updater(Uri? releases = null, string? directory = null)
    {
        this.releases = releases ?? AppRelease.Releases;
        this.directory = directory ?? Path.Combine(Settings.DataDirectory, "updates");
    }

    public void Configure(bool automatic)
    {
        if (automatic == (schedule != null)) return;
        schedule?.Cancel(); schedule?.Dispose(); schedule = null;
        if (!automatic) return;
        schedule = new CancellationTokenSource();
        _ = Schedule(schedule.Token);
    }

    async Task Schedule(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Check();
                await Task.Delay(TimeSpan.FromHours(24), token);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }

    void SetState(UpdateState state)
    {
        State = state;
        Changed?.Invoke();
    }

    public async Task Check()
    {
        if (IsBusy) return;
        Error = null;
        SetState(UpdateState.Checking);
        try
        {
            var release = new AppRelease(await http.GetStringAsync(new Uri(releases, "latest/download/version.txt")));
            Release = new SemanticVersion(release.Tag).CompareTo(new SemanticVersion(AppRelease.CurrentVersion)) > 0 ? release : null;
            SetState(Release == null ? UpdateState.UpToDate : UpdateState.Available);
        }
        catch (Exception failure) { Error = failure.Message; SetState(UpdateState.Failed); }
    }

    public async Task Install(Func<Task> quit)
    {
        if (IsBusy || Release == null) return;
        var release = Release;
        Progress = 0; Error = null;
        SetState(UpdateState.Downloading);
        try
        {
            var work = Path.Combine(directory, Guid.NewGuid().ToString());
            Directory.CreateDirectory(work);
            var log = Path.Combine(work, "update.log");
            void Log(string message) => File.AppendAllText(log, message + Environment.NewLine);
            Log($"Updating {AppRelease.CurrentVersion} to {release.Tag}");
            var installer = Path.Combine(work, "LifeNarrator-Setup.exe");
            var checksums = await http.GetStringAsync(release.AssetURL(releases, "checksums-windows.txt"));
            var expected = ReleaseChecksums.Sha256("LifeNarrator-Setup.exe", checksums);
            using (var response = await http.GetAsync(release.AssetURL(releases, "LifeNarrator-Setup.exe"), HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                await using var source = await response.Content.ReadAsStreamAsync();
                await using var target = File.Create(installer);
                var buffer = new byte[1_048_576];
                long downloaded = 0;
                int length;
                while ((length = await source.ReadAsync(buffer)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, length));
                    downloaded += length;
                    var progress = response.Content.Headers.ContentLength is > 0 and var total ? (int)(downloaded * 100 / total) : 0;
                    if (progress != Progress) { Progress = progress; Changed?.Invoke(); }
                }
            }
            await Task.Run(async () =>
            {
                await using var file = File.OpenRead(installer);
                var actual = Convert.ToHexString(await SHA256.HashDataAsync(file)).ToLowerInvariant();
                if (actual != expected) throw new InvalidDataException($"SHA-256 mismatch: expected {expected}, received {actual}");
                Log("SHA-256 verified: " + actual);
                UpdateSignature.Check(installer, Environment.ProcessPath!, Log);
            });
            var script = Path.Combine(work, "install.ps1");
            await File.WriteAllTextAsync(script, HelperScript, new UTF8Encoding(true));
            File.Delete(FailurePath);
            var helper = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"))
            { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = work };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
                "-ParentID", Environment.ProcessId.ToString(), "-InstallDirectory", Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory),
                "-FailurePath", FailurePath }) helper.ArgumentList.Add(argument);
            using var process = Process.Start(helper)!;
            await quit();
        }
        catch (Exception failure) { Error = failure.Message; SetState(UpdateState.Failed); }
    }

    public UpdateFailure? PreviousFailure() => File.Exists(FailurePath)
        ? JsonSerializer.Deserialize<UpdateFailure>(File.ReadAllText(FailurePath))! : null;

    public void Dispose()
    {
        schedule?.Cancel(); schedule?.Dispose(); http.Dispose();
    }

    internal const string HelperScript = """
        param([int]$ParentID, [string]$InstallDirectory, [string]$FailurePath)
        $ErrorActionPreference = 'Stop'
        $log = Join-Path $PSScriptRoot 'install.log'
        $helperLog = Join-Path $PSScriptRoot 'update.log'
        try {
            $parent = Get-Process -Id $ParentID -ErrorAction SilentlyContinue
            if ($null -ne $parent -and !$parent.WaitForExit(60000)) { throw 'LifeNarrator did not quit within 60 seconds.' }
            Add-Content $helperLog 'Shell exited; starting installer.'
            $installer = Join-Path $PSScriptRoot 'LifeNarrator-Setup.exe'
            $setup = Start-Process $installer -ArgumentList "/VERYSILENT /CURRENTUSER /SUPPRESSMSGBOXES /NORESTART /UPDATE=1 /DIR=`"$InstallDirectory`" /LOG=`"$log`"" -PassThru -Wait
            Add-Content $helperLog "Installer exit code: $($setup.ExitCode)"
            if ($setup.ExitCode -ne 0) { throw "Installer exit code: $($setup.ExitCode)" }
        } catch {
            Add-Content $helperLog $_.Exception.Message
            if (!(Test-Path $log)) { Copy-Item $helperLog $log }
            @{ Message = $_.Exception.Message; LogPath = $log } | ConvertTo-Json | Set-Content $FailurePath -Encoding UTF8
            exit 1
        }
        """;
}
