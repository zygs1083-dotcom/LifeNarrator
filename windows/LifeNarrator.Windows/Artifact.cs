using System.Text.Json;

namespace LifeNarrator.Windows;

internal static class Artifact
{
    public static readonly string DirectoryPath = Path.GetFullPath("artifacts");
    public static string PathFor(string name) => Path.Combine(DirectoryPath, name);
    public static void Write(string name, object value) => File.WriteAllText(PathFor(name),
        JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }));
}
