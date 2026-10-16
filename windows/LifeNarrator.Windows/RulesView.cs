using System.Text.Json;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;

namespace LifeNarrator.Windows;

internal sealed class RulesView : StackPanel
{
    readonly Settings settings;
    readonly Companion companion;
    readonly Window owner;
    readonly Func<Task> configure;
    readonly Action<Func<Task>> run;
    readonly Texts text;
    bool expanded;
    public RulesView(Settings settings, Companion companion, Window owner, Func<Task> configure, Action<Func<Task>> run)
    {
        this.settings = settings; this.companion = companion; this.owner = owner; this.configure = configure; this.run = run;
        text = new Texts(settings); Spacing = 14; Render();
    }
    string Count(int count) => text["format.count"].Replace("%d", count.ToString());
    string Label(JsonElement rule) => rule.GetProperty("label").GetProperty(settings.EffectiveLanguage).GetString()!;
    void Render()
    {
        Children.Clear();
        var own = Views.Stack();
        if (settings.Rules.Length == 0)
        {
            var icon = Views.Icon("\uE8F2", 44); icon.HorizontalAlignment = HorizontalAlignment.Center;
            icon.Bind(TextBlock.ForegroundProperty, icon.GetResourceObservable("Soft"));
            var title = Views.Label(text["rules.empty.title"]); title.FontSize = 15; title.FontWeight = Avalonia.Media.FontWeight.SemiBold;
            title.HorizontalAlignment = HorizontalAlignment.Center;
            var hint = Views.Caption(text["rules.empty.body"]); hint.MaxWidth = 430; hint.TextAlignment = Avalonia.Media.TextAlignment.Center;
            hint.HorizontalAlignment = HorizontalAlignment.Center;
            var add = Views.Primary(text["rules.empty.action"], () => run(() => Edit(null))); Views.Hue(add, 320); add.HorizontalAlignment = HorizontalAlignment.Center;
            AutomationProperties.SetAutomationId(add, "rule-add");
            own.Children.Add(new Border { Padding = new Thickness(0, 16), Child = Views.Stack(icon, title, hint, add) });
        }
        else
        {
            foreach (var rule in settings.Rules)
            {
                var id = rule.GetProperty("id").GetString()!;
                var labels = Views.Stack(Views.Label(Label(rule))); labels.Spacing = 4;
                if (rule.TryGetProperty("input", out var input) && input.ValueKind == JsonValueKind.String) labels.Children.Add(Views.Caption(input.GetString()!));
                var toggle = Views.Switch(Label(rule), rule.GetProperty("enabled").GetBoolean(), enabled => run(async () =>
                {
                    var updated = JsonNode.Parse(rule.GetRawText())!; updated["enabled"] = enabled;
                    settings.Rules = settings.Rules.Select(r => r.GetProperty("id").GetString() == id ? JsonSerializer.SerializeToElement(updated) : r).ToArray();
                    Render(); await configure();
                }));
                AutomationProperties.SetAutomationId(toggle, "rule-enabled-" + id);
                var chip = Views.Chip(rule.GetProperty("kind").GetString() switch { "person" => "\uE77B", "site" => "\uE774", "time" => "\uE823", "topic" => "\uE8EC", _ => "\uE737" });
                Views.Hue(chip, rule.GetProperty("kind").GetString() switch { "person" => 320, "site" => 222, "time" => 255, "topic" => 42, _ => 200 });
                if (own.Children.Count > 0)
                { var line = new Border { Height = 1 }; line.Bind(Border.BackgroundProperty, this.GetResourceObservable("Stroke")); own.Children.Add(line); }
                own.Children.Add(Views.Row(Views.Horizontal(chip, labels), Views.Horizontal(Views.Caption(text["kind." + rule.GetProperty("kind").GetString()]), toggle,
                    Views.IconButton(text["rules.edit"], "\uE70F", () => run(() => Edit(rule))),
                    Views.IconButton(text["delete"], "\uE74D", () => run(async () =>
                    { settings.Rules = settings.Rules.Where(r => r.GetProperty("id").GetString() != id).ToArray(); Render(); await configure(); })))));
            }
            var add = Views.Primary(text["rules.add"], () => run(() => Edit(null))); AutomationProperties.SetAutomationId(add, "rule-add"); own.Children.Add(add);
        }
        Children.Add(Views.Card(Views.Row(Views.Heading(text["rules.user"], "\uE8A5"), Views.Badge(Count(settings.Rules.Length))), 150, own));
        var enabled = Catalog.BuiltinRules.Any(r => !settings.DisabledBuiltinIds.Contains(r.GetProperty("id").GetString()!));
        var all = Views.Switch(text["rules.builtin"], enabled, value => run(async () =>
        { settings.DisabledBuiltinIds = value ? [] : Catalog.BuiltinRules.Select(r => r.GetProperty("id").GetString()!).ToArray(); Render(); await configure(); }));
        AutomationProperties.SetAutomationId(all, "builtin-enabled");
        var list = Views.Stack(); list.IsVisible = expanded;
        foreach (var kind in new[] { "app", "site", "time" })
        {
            var rules = Catalog.BuiltinRules.Where(r => r.GetProperty("kind").GetString() == kind).ToArray();
            list.Children.Add(Views.Horizontal(Views.Label(text["kind." + kind]), Views.Badge(Count(rules.Length))));
            foreach (var rule in rules)
            {
                var id = rule.GetProperty("id").GetString()!;
                var toggle = Views.Switch(Label(rule), !settings.DisabledBuiltinIds.Contains(id), value => run(async () =>
                {
                    settings.DisabledBuiltinIds = value ? settings.DisabledBuiltinIds.Where(x => x != id).ToArray() : [..settings.DisabledBuiltinIds, id];
                    await configure();
                })); toggle.IsEnabled = enabled; AutomationProperties.SetAutomationId(toggle, id);
                var quips = Views.Stack(); quips.IsVisible = false;
                foreach (var quip in rule.GetProperty("quips").EnumerateArray().Where(q => q.GetProperty("lang").GetString() == settings.EffectiveLanguage
                    && q.GetProperty("persona").GetString() == settings.Persona))
                    quips.Children.Add(Views.Caption(quip.GetProperty("text").GetString() + " " + string.Join("", quip.GetProperty("emoji").EnumerateArray().Select(e => e.GetString()))));
                list.Children.Add(Views.Row(Views.Button("› " + Label(rule), () => quips.IsVisible = !quips.IsVisible), toggle)); list.Children.Add(quips);
            }
        }
        Children.Add(Views.Card(Views.Row(Views.Heading(text["rules.builtin"], "\uE7B8"), Views.Horizontal(Views.Badge(Count(Catalog.BuiltinRules.Length)), all)), 150,
            Views.Caption(text["rules.builtin.hint"]), Views.Button("› " + text["rules.builtin.show"], () => { expanded = !expanded; list.IsVisible = expanded; }), list));
    }
    internal async Task Edit(JsonElement? rule)
    {
        var dialog = new Window { Width = 500, Height = 270, CanResize = false, Title = text[rule == null ? "input.title" : "rules.edit"],
            WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = owner.FontFamily };
        var input = new TextBox { Text = rule?.GetProperty("input").GetString() ?? "", Watermark = text["input.placeholder"] };
        AutomationProperties.SetName(input, text["input.title"]); AutomationProperties.SetAutomationId(input, "rule-input");
        var status = Views.Caption(text["input.hint"]);
        var save = Views.Primary(text["memory.save"], () => { }); save.IsEnabled = !string.IsNullOrWhiteSpace(input.Text);
        input.TextChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(input.Text);
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false; input.IsEnabled = false; status.Text = text["input.compiling"];
            try
            {
                var compiled = await companion.Call("rules.compile", new { input = input.Text!.Trim() });
                settings.Rules = rule == null ? [..settings.Rules, compiled] : settings.Rules.Select(r =>
                    r.GetProperty("id").GetString() == rule.Value.GetProperty("id").GetString() ? compiled : r).ToArray();
                await configure(); await companion.Refresh(); Render(); dialog.Close();
            }
            catch (Exception failure) { status.Text = failure.Message; }
            finally { save.IsEnabled = true; input.IsEnabled = true; }
        };
        dialog.Content = new Border { Padding = new Thickness(24), Child = Views.Stack(Views.Label(text["input.title"]), input, status,
            Views.Row(Views.Button(text["cancel"], () => dialog.Close()), save)) };
        await dialog.ShowDialog(owner);
    }
}
