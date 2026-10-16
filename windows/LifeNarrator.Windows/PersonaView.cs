using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;

namespace LifeNarrator.Windows;

internal sealed class PersonaView : StackPanel
{
    public PersonaView(Settings settings, Companion? companion, Window owner, Func<Task> configure, Action<Func<Task>> run)
    {
        var text = new Texts(settings); Spacing = 10;
        var choices = (WrapPanel)Views.Choices(settings.Personas.Select(p => (p.Id, p.Emoji + "  " + p.Name.Text(settings.EffectiveLanguage),
            p.Caption.Text(settings.EffectiveLanguage))), settings.Persona, id => run(async () => { settings.Persona = id; await configure(); }));
        foreach (var button in choices.Children.OfType<ToggleButton>()) { button.Width = 162; button.Margin = new Thickness(0, 0, 10, 10); }
        foreach (var profile in settings.Personas.Where(p => p.Id.StartsWith("custom.")))
        {
            var delete = Views.IconButton(text["persona.custom.delete"] + " · " + profile.Name.Text(settings.EffectiveLanguage), "\uE74D", () => run(async () =>
            {
                settings.CustomPersonas = settings.CustomPersonas.Where(p => p.GetProperty("id").GetString() != profile.Id).ToArray();
                if (settings.Persona == profile.Id) settings.Persona = "sharp";
                await configure(); ((SettingsWindow)owner).Refresh();
            }));
            var button = choices.Children.OfType<ToggleButton>().Single(b => AutomationProperties.GetAutomationId(b) == "choice-" + profile.Id);
            var index = choices.Children.IndexOf(button); choices.Children.Remove(button); button.Margin = new Thickness(0);
            var card = Views.Stack(button, delete); card.Spacing = 6; card.Width = 162; card.Margin = new Thickness(0, 0, 10, 10);
            choices.Children.Insert(index, card);
        }
        var add = Views.Button(text["persona.custom.add"], () => run(Create));
        add.Content = Views.Stack(Views.Icon("\uE710", 22), Views.Label(text["persona.custom.add"]), Views.Caption(text["persona.custom.hint"]));
        add.Width = 162; add.MinHeight = 110; add.CornerRadius = new CornerRadius(14); add.Padding = new Thickness(12);
        add.IsEnabled = companion != null && (settings.Provider.Kind == "api" && settings.Provider.Model.Trim().Length > 0
            || settings.Provider.Kind == "builtin" && settings.SelectedDownload.State == ModelDownloadState.Ready);
        AutomationProperties.SetAutomationId(add, "persona-add"); choices.Children.Add(add); Children.Insert(0, choices);
        if (!add.IsEnabled) Children.Add(Views.Caption(text[settings.Provider.Kind == "none" ? "persona.custom.noModel" : settings.Provider.Kind == "builtin" ? "persona.custom.downloadModel" : "persona.custom.configureModel"]));
        async Task Create()
        {
            var dialog = new Window { Width = 508, Height = 280, CanResize = false, Title = text["persona.custom.add"], FontFamily = owner.FontFamily,
                WindowStartupLocation = WindowStartupLocation.CenterOwner };
            var input = new TextBox { Watermark = text["persona.custom.placeholder"] };
            AutomationProperties.SetName(input, text["persona.custom.description"]);
            var error = Views.Caption("");
            var generate = Views.Primary(text["persona.custom.generate"], () => { }); generate.IsEnabled = false;
            var cancel = Views.Button(text["persona.custom.cancel"], () => dialog.Close());
            input.TextChanged += (_, _) => generate.IsEnabled = !string.IsNullOrWhiteSpace(input.Text);
            generate.Click += async (_, _) =>
            {
                generate.IsEnabled = cancel.IsEnabled = input.IsEnabled = false; error.Text = text["persona.custom.generating"];
                try
                {
                    var profile = await companion!.Call("personas.generate", new { input = input.Text!.Trim() });
                    settings.CustomPersonas = [..settings.CustomPersonas, profile]; settings.Persona = profile.GetProperty("id").GetString()!;
                    await configure(); ((SettingsWindow)owner).Refresh(); dialog.Close();
                }
                catch (Exception failure) { error.Text = failure.Message; }
                finally { generate.IsEnabled = cancel.IsEnabled = input.IsEnabled = true; }
            };
            dialog.Content = new Border { Padding = new Thickness(24), Child = Views.Stack(Views.Label(text["persona.custom.add"]),
                Views.Label(text["persona.custom.description"]), input, error, Views.Row(cancel, generate)) };
            await dialog.ShowDialog(owner);
        }
    }
}
