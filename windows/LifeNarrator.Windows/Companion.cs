using System.Text.Json;

namespace LifeNarrator.Windows;

internal sealed record ChatTurn(string Id, string User, string Reply, string? Notice);
internal sealed record MemoryEntry(string Id, string Kind, string Text, string Source, DateTimeOffset CreatedAt,
    DateTimeOffset LastUsedAt, int Uses, bool Pinned);
internal sealed record GrowthNumbers(int Level, int Experience, int ActiveDays, int ConsecutiveDays,
    int Narrations, int ChatMessages, int RulesLearned, string[] Unlocked);
internal sealed record GrowthUnlock(string Id, int Level, string Name);
internal sealed record GrowthInfo(GrowthNumbers State, string Name, string Title, int? NextLevelExperience,
    int DaysKnown, GrowthUnlock[] Unlocks)
{
    public bool Has(string id) => State.Unlocked.Contains(id);
}

internal sealed class Companion(Func<string, object, Task<JsonElement>> call)
{
    public GrowthInfo? Growth { get; private set; }
    public MemoryEntry[] Memories { get; private set; } = [];
    public event Action? Changed;
    public Task<JsonElement> Call(string method, object parameters) => call(method, parameters);
    public async Task Refresh()
    {
        var growth = await Call("growth.state", new { });
        var memories = await Call("memory.list", new { });
        Growth = growth.Read<GrowthInfo>(); Memories = memories.Read<MemoryEntry[]>();
        Changed?.Invoke();
    }
    public string Name(Settings settings) => Growth is { } g && g.Has("spriteName") && g.Name.Length > 0
        ? g.Name : Catalog.Personas.Single(p => p.Id == settings.Persona).Name.Text(settings.EffectiveLanguage);
}
