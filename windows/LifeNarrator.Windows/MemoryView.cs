using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace LifeNarrator.Windows;

internal sealed class MemoryView : StackPanel
{
    static readonly string[] Kinds = ["nickname", "fact", "preference", "episode"];
    readonly Settings settings;
    readonly Texts text;
    readonly Companion companion;
    readonly Window owner;
    readonly Func<Task> configure;
    readonly Action<Func<Task>> run;

    public MemoryView(Settings settings, Companion companion, Window owner, Func<Task> configure, Action<Func<Task>> run)
    {
        this.settings = settings; this.companion = companion; this.owner = owner; this.configure = configure; this.run = run;
        text = new Texts(settings); Spacing = 12;
        Children.Add(Views.Caption(text["memory.privacy"]));
        var add = Views.Button(text["memory.add"], () => run(() => Edit(null))); add.IsEnabled = settings.MemoryEnabled; add.HorizontalAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetAutomationId(add, "memory-add");
        var clear = Views.Button(text["memory.clear"], () => run(async () =>
        {
            if (await Confirm(text["memory.clear.confirm"], text["memory.clear.hint"]))
            { await companion.Call("memory.clear", new { }); await companion.Refresh(); }
        })); clear.IsEnabled = companion.Memories.Length > 0;
        AutomationProperties.SetAutomationId(clear, "memory-clear");
        Children.Add(Views.Card(text["memory.title"],
            Views.Toggle(text["memory.enabled"], settings.MemoryEnabled, enabled => run(async () =>
            { settings.MemoryEnabled = enabled; await configure(); await companion.Refresh(); })), Views.Row(add, clear)));
        foreach (var kind in Kinds)
        {
            var entries = companion.Memories.Where(m => m.Kind == kind).OrderByDescending(m => m.Pinned).ToArray();
            var rules = kind == "preference" ? settings.Rules : [];
            var rows = new List<Control>();
            foreach (var entry in entries)
            {
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                actions.Children.Add(Views.Button(text[entry.Pinned ? "memory.unpin" : "memory.pin"], () => run(async () =>
                { await companion.Call("memory.pin", new { entry.Id, pinned = !entry.Pinned }); await companion.Refresh(); })));
                actions.Children.Add(Views.Button(text["memory.edit"], () => run(() => Edit(entry))));
                actions.Children.Add(Views.Button(text["delete"], () => run(async () =>
                {
                    if (await Confirm(text["memory.confirm.delete"], entry.Text))
                    { await companion.Call("memory.delete", new { entry.Id }); await companion.Refresh(); }
                })));
                rows.Add(Views.Stack(Views.Label((entry.Pinned ? "• " : "") + entry.Text), actions));
            }
            foreach (var rule in rules)
            {
                var label = rule.TryGetProperty("input", out var input) && input.ValueKind == System.Text.Json.JsonValueKind.String
                    ? input.GetString()! : rule.GetProperty("label").GetProperty(settings.EffectiveLanguage).GetString()!;
                rows.Add(Views.Row(Views.Label(text["memory.rule"] + " · " + label), Views.Button(text["memory.rule.delete"], () => run(async () =>
                {
                    if (!await Confirm(text["memory.rule.delete"], label)) return;
                    settings.Rules = settings.Rules.Where(r => r.GetProperty("id").GetString() != rule.GetProperty("id").GetString()).ToArray();
                    await configure(); await companion.Refresh();
                }))));
            }
            if (rows.Count == 0) rows.Add(Views.Caption(text["memory.empty"]));
            Children.Add(Views.Card(text["memory.kind." + kind] + " · " + (entries.Length + rules.Length), rows.ToArray()));
        }
    }

    async Task Edit(MemoryEntry? entry)
    {
        var dialog = new Window { Title = text[entry == null ? "memory.add" : "memory.edit"], Width = 460, Height = 330,
            CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var category = new ComboBox { ItemsSource = Kinds.Select(k => text["memory.kind." + k]).ToArray(),
            SelectedIndex = Array.IndexOf(Kinds, entry?.Kind ?? "fact"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var content = new TextBox { Text = entry?.Text ?? "", AcceptsReturn = true, Height = 72, TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetName(category, text["memory.category"]); AutomationProperties.SetName(content, text["memory.content"]);
        AutomationProperties.SetAutomationId(content, "memory-content");
        var error = Views.Caption(""); error.Bind(TextBlock.ForegroundProperty, dialog.GetResourceObservable("ErrorInk"));
        var save = Views.Button(text["memory.save"], () => { });
        bool Valid() => System.Globalization.StringInfo.ParseCombiningCharacters(content.Text?.Trim() ?? "").Length is > 0 and <= 40;
        save.IsEnabled = Valid(); content.TextChanged += (_, _) => save.IsEnabled = Valid();
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            try
            {
                var kind = Kinds[category.SelectedIndex]; var value = content.Text!.Trim();
                var result = entry == null
                    ? await companion.Call("memory.add", new { kind, text = value })
                    : await companion.Call("memory.edit", new { entry.Id, kind, text = value });
                if (entry == null && result.ValueKind == System.Text.Json.JsonValueKind.Null) { error.Text = text["memory.duplicate"]; return; }
                await companion.Refresh(); dialog.Close();
            }
            catch (Exception failure) { error.Text = failure.Message; }
            finally { save.IsEnabled = Valid(); }
        };
        dialog.Content = new Border { Padding = new Thickness(20), Child = Views.Stack(Views.Field(text["memory.category"], category),
            Views.Field(text["memory.content"], content), Views.Caption(text["memory.length"]), error,
            Views.Row(Views.Button(text["cancel"], () => dialog.Close()), save)) };
        await dialog.ShowDialog(owner);
    }

    async Task<bool> Confirm(string title, string hint)
    {
        var dialog = new Window { Title = title, Width = 460, Height = 210, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        dialog.Content = new Border { Padding = new Thickness(20), Child = Views.Stack(Views.Label(title), Views.Caption(hint),
            Views.Row(Views.Button(text["cancel"], () => dialog.Close(false)), Views.Button(title, () => dialog.Close(true)))) };
        return await dialog.ShowDialog<bool>(owner);
    }
}
