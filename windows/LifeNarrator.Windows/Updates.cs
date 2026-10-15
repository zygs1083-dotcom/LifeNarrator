using System.Reflection;
using System.Text.RegularExpressions;

namespace LifeNarrator.Windows;

internal sealed class SemanticVersion : IComparable<SemanticVersion>
{
    readonly string[] numbers, prerelease;
    public SemanticVersion(string value)
    {
        var match = Regex.Match(value, @"^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$", RegexOptions.NonBacktracking);
        if (!match.Success || match.Length != value.Length) throw new InvalidDataException("Invalid semantic version: " + value);
        numbers = [match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value];
        prerelease = match.Groups[4].Success ? match.Groups[4].Value.Split('.') : [];
        if (prerelease.Any(p => Numeric(p) && p.Length > 1 && p[0] == '0'))
            throw new InvalidDataException("Invalid semantic version: " + value);
    }

    static bool Numeric(string value) => value.All(c => c is >= '0' and <= '9');
    static int CompareNumber(string left, string right) => left.Length != right.Length
        ? left.Length.CompareTo(right.Length) : string.CompareOrdinal(left, right);

    public int CompareTo(SemanticVersion? other)
    {
        for (var i = 0; i < 3; i++)
        {
            var comparison = CompareNumber(numbers[i], other!.numbers[i]);
            if (comparison != 0) return comparison;
        }
        if (prerelease.Length == 0 || other!.prerelease.Length == 0)
            return (prerelease.Length == 0).CompareTo(other!.prerelease.Length == 0);
        for (var i = 0; i < Math.Min(prerelease.Length, other.prerelease.Length); i++)
        {
            var left = prerelease[i]; var right = other.prerelease[i];
            var comparison = Numeric(left) != Numeric(right) ? (Numeric(left) ? -1 : 1)
                : Numeric(left) ? CompareNumber(left, right) : string.CompareOrdinal(left, right);
            if (comparison != 0) return comparison;
        }
        return prerelease.Length.CompareTo(other.prerelease.Length);
    }
}

internal static class ReleaseChecksums
{
    public static string Sha256(string filename, string text)
    {
        string? result = null;
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length != 2 || fields[0].Length != 64 || !fields[0].All(char.IsAsciiHexDigit))
                throw new InvalidDataException("Invalid SHA-256 checksum: " + line);
            var name = fields[1].Trim();
            if (name.StartsWith('*')) name = name[1..];
            if (name != filename) continue;
            if (result != null) throw new InvalidDataException("Duplicate SHA-256 checksum: " + filename);
            result = fields[0].ToLowerInvariant();
        }
        return result ?? throw new InvalidDataException("Missing SHA-256 checksum: " + filename);
    }
}

internal sealed record AppRelease
{
    public string Tag { get; }
    public AppRelease(string versionText)
    {
        var version = versionText.Trim();
        _ = new SemanticVersion(version);
        Tag = version.StartsWith('v') ? version : "v" + version;
    }
    public static string CurrentVersion => typeof(AppRelease).Assembly
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];
    public static readonly Uri Releases = new("https://github.com/zygs1083-dotcom/LifeNarrator/releases/");
    public Uri AssetURL(Uri releases, string filename) => new(releases, "download/" + Tag + "/" + filename);
}
