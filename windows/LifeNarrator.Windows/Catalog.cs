using System.Reflection;
using System.Text.Json;

namespace LifeNarrator.Windows;

internal sealed record Localized(string Zh, string En)
{
    public string Text(string lang) => lang == "zh" ? Zh : En;
}
internal sealed record ProviderPreset(string Id, Localized Name, string Group, string Api,
    string BaseURL, string Structured, bool KeyRequired, string? KeyURL, string[] SuggestedModels);
internal sealed record PersonaPreset(string Id, string Emoji, Localized Name, Localized Caption);

internal static class Catalog
{
    public static readonly DownloadableModel[] Models = Read<DownloadableModel[]>("models.json");
    public static readonly ProviderPreset[] Providers = Read<ProviderPreset[]>("providers.json");
    public static readonly JsonElement[] BuiltinRules = Read<JsonElement>("quips.json").GetProperty("rules").EnumerateArray().ToArray();
    public static readonly PersonaPreset[] Personas = Read<PersonaPreset[]>("personas.json");
    public static T Read<T>(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("LifeNarrator." + name)!;
        return JsonSerializer.Deserialize<T>(stream, Protocol.Json)!;
    }
}

internal sealed class Texts(Settings settings)
{
    static readonly Dictionary<string, string> Chinese = Catalog.Read<Dictionary<string, string>>("zh.json");
    static readonly Dictionary<string, string> English = Catalog.Read<Dictionary<string, string>>("en.json");
    public string this[string key] => (settings.EffectiveLanguage == "zh" ? Chinese : English)[key];
}
