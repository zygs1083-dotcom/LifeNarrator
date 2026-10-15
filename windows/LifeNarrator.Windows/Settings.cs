using System.ComponentModel;
using System.Globalization;
using System.Text.Json.Serialization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace LifeNarrator.Windows;

internal sealed class Settings
{
    public string Liveliness { get; set; } = "lively";
    public string Persona { get; set; } = "gentle";
    public string Lang { get; set; } = "zh";
    public string Language { get; set; } = "system";
    public bool OnboardingCompleted { get; set; }
    public bool LaunchAtLogin { get; set; } = true;
    [JsonIgnore] public string EffectiveLanguage => Language == "system"
        ? (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? "zh" : "en") : Language;
    public bool Paused { get; set; }
    public double MarkGap { get; set; } = 2;
    public double Dwell { get; set; } = 3;
    public int MaxOnScreen { get; set; } = 3;
    public string[] Blacklist { get; set; } = [];
    public bool MemoryEnabled { get; set; } = true;
    public string BubbleShape { get; set; } = "automatic";
    public string BubbleTheme { get; set; } = "random";
    public string Emoji { get; set; } = "";
    public JsonElement[] Rules { get; set; } = [];
    public string ActiveShape(GrowthInfo? growth) => BubbleShape == "star" && growth?.Has("starBubble") == true ? "star" : "automatic";
    public string ActiveTheme(GrowthInfo? growth) => BubbleTheme == "starry" && growth?.Has("starryTheme") == true ? "starry" : "random";
    public string[] ActiveEmoji(string[] original, GrowthInfo? growth) => growth?.Has("emoji") == true && Emoji.Length > 0 ? [Emoji] : original;
    public ProviderSettings Provider { get; set; } = new();

    public static string DataDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LifeNarrator");
    public static string FilePath => Path.Combine(DataDirectory, "settings.json");

    public static Settings Load()
    {
        Directory.CreateDirectory(DataDirectory);
        if (!File.Exists(FilePath)) { var defaults = new Settings(); defaults.Save(); return defaults; }
        var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Protocol.Json)
            ?? throw new InvalidDataException("settings.json must contain an object");
        if (settings.Liveliness is not ("quiet" or "lively" or "rowdy")
            || settings.Persona is not ("sharp" or "gentle" or "chuuni" or "teacher" or "mom" or "hype" or "cat")
            || settings.Lang is not ("zh" or "en") || settings.Language is not ("system" or "zh" or "en") || !double.IsFinite(settings.MarkGap) || settings.MarkGap < 0
            || !double.IsFinite(settings.Dwell) || settings.Dwell <= 0 || settings.MaxOnScreen <= 0
            || settings.BubbleShape is not ("automatic" or "star") || settings.BubbleTheme is not ("random" or "starry")
            || !new[] { "", "✨", "🌷", "😺", "🥹", "🫶", "🌈", "🎉" }.Contains(settings.Emoji)
            || settings.Provider.Kind is not ("none" or "api"))
            throw new InvalidDataException("Invalid Windows shell settings");
        return settings;
    }

    public void Save() => File.WriteAllText(FilePath, JsonSerializer.Serialize(this,
        new JsonSerializerOptions(Protocol.Json) { WriteIndented = true }));

    public object GeneratorConfiguration() => Provider.Kind == "none" ? (object)new { kind = "none" } : new
    {
        kind = "api", Provider.PresetId, Provider.Model, Provider.BaseURL, Provider.Structured,
        key = CredentialStore.Read(Provider.PresetId)
    };

    public object Configuration() => new
    {
        settings = new { Liveliness, MarkGap, Paused, Blacklist, Persona, lang = EffectiveLanguage,
            disabledBuiltinIds = Array.Empty<string>(), MaxOnScreen, ownProcessID = Environment.ProcessId, MemoryEnabled },
        rules = Rules, customPersonas = Array.Empty<object>(),
        generator = GeneratorConfiguration(),
        dataDirectory = DataDirectory
    };
}

internal sealed class ProviderSettings
{
    public string Kind { get; set; } = "none";
    public string PresetId { get; set; } = "custom-openai";
    public string Model { get; set; } = "";
    public string? BaseURL { get; set; }
    public string? Structured { get; set; }
}

internal static class CredentialStore
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Credential
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public nint CredentialBlob;
        public uint Persist, AttributeCount;
        public nint Attributes;
        public string? TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWriteW(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredReadW(string target, uint type, uint flags, out nint credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] static extern void CredFree(nint credential);

    public static string Read(string provider)
    {
        if (!CredReadW("LifeNarrator/" + provider, 1, 0, out var pointer))
        {
            if (Marshal.GetLastWin32Error() == 1168) return "";
            throw new Win32Exception();
        }
        try
        {
            var value = Marshal.PtrToStructure<Credential>(pointer);
            if (value.CredentialBlobSize == 0) return "";
            return Marshal.PtrToStringUni(value.CredentialBlob, (int)value.CredentialBlobSize / 2)!;
        }
        finally { CredFree(pointer); }
    }

    public static void Delete(string provider)
    {
        if (!CredDeleteW("LifeNarrator/" + provider, 1, 0) && Marshal.GetLastWin32Error() != 1168)
            throw new Win32Exception();
    }

    public static void Write(string provider, string key)
    {
        var blob = Marshal.StringToCoTaskMemUni(key);
        try
        {
            var credential = new Credential { Type = 1, TargetName = "LifeNarrator/" + provider,
                Persist = 2, UserName = provider, CredentialBlob = blob,
                CredentialBlobSize = (uint)Encoding.Unicode.GetByteCount(key) };
            if (!CredWriteW(ref credential, 0)) throw new Win32Exception();
        }
        finally { Marshal.ZeroFreeCoTaskMemUnicode(blob); }
    }
}
