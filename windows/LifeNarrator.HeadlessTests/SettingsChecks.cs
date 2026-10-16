using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using LifeNarrator.Windows;

internal static class SettingsChecks
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDeleteW(string target, uint type, uint flags);

    public static void Run()
    {
        var settings = new Settings { Liveliness = "rowdy", Persona = "cat", Lang = "en", Paused = true,
            MarkGap = 7, Dwell = 12, MaxOnScreen = 4, Blacklist = ["private"],
            Provider = new ProviderSettings { Kind = "api", PresetId = "custom-openai", Model = "fixture", Vision = true, BaseURL = "http://localhost:18765/v1" } };
        var json = JsonSerializer.Serialize(settings, Protocol.Json);
        var roundTrip = JsonSerializer.Deserialize<Settings>(json, Protocol.Json)!;
        if (JsonSerializer.Serialize(roundTrip, Protocol.Json) != json || json.Contains("key", StringComparison.OrdinalIgnoreCase))
            throw new Exception("Settings round trip or credential separation failed");
        if (!roundTrip.Provider.Vision || JsonSerializer.Deserialize<ProviderSettings>("{}", Protocol.Json)!.Vision)
            throw new Exception("Vision settings default or persistence failed");
        if (!OperatingSystem.IsWindows()) return;
        var provider = "ci-" + Guid.NewGuid();
        const string key = "fixture-密钥-😺";
        if (CredentialStore.Read(provider) != "") throw new Exception("Unexpected existing credential");
        CredentialStore.Write(provider, key);
        try
        {
            if (CredentialStore.Read(provider) != key) throw new Exception("Credential round trip failed");
            CredentialStore.Write(provider, "");
            if (CredentialStore.Read(provider) != "") throw new Exception("Empty credential round trip failed");
        }
        finally { if (!CredDeleteW("LifeNarrator/" + provider, 1, 0)) throw new Win32Exception(); }
        Console.WriteLine("PASS: settings round trip and Unicode Windows credential round trip; no plaintext key in settings");
    }
}
