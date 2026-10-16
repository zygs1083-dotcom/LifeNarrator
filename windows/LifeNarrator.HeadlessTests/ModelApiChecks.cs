using System.Net;
using System.Net.Sockets;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LifeNarrator.Windows;

internal static class ModelApiChecks
{
    public static void Run()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        using var server = new HttpListener(); server.Prefixes.Add($"http://127.0.0.1:{port}/"); server.Start();
        var settings = new Settings { Language = "en", Provider = new ProviderSettings { Kind = "api", PresetId = "ollama", Model = "original", BaseURL = $"http://127.0.0.1:{port}/v1" } };
        var configured = 0;
        var window = new Window { Width = 780, Height = 580, Content = new ModelView(settings,
            () => { configured++; return Task.CompletedTask; }, () => Task.FromResult(1d)) };
        window.Show(); window.UpdateLayout();
        var fetch = window.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "fetch-models");
        async Task Reply(string json, int code = 200)
        {
            var request = await server.GetContextAsync();
            if (request.Request.Url!.AbsolutePath != "/v1/models") throw new Exception("Model list used the wrong endpoint");
            request.Response.StatusCode = code;
            using var output = new StreamWriter(request.Response.OutputStream); await output.WriteAsync(json);
        }
        void Fetch(Task reply)
        {
            fetch.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if (fetch.IsEnabled) throw new Exception("Model fetch did not disable its button while waiting");
            async Task Completed() { await reply; while (!fetch.IsEnabled) await Task.Delay(5); }
            var task = Completed().WaitAsync(TimeSpan.FromSeconds(10));
            var frame = new DispatcherFrame(); task.ContinueWith(_ => Dispatcher.UIThread.Post(() => frame.Continue = false));
            Dispatcher.UIThread.PushFrame(frame); task.GetAwaiter().GetResult(); window.UpdateLayout();
        }
        Fetch(Reply("{\"data\":[{\"id\":\"z-model\"},{\"id\":\"a-model\"},{\"id\":\"z-model\"}]}"));
        var suggestions = window.GetVisualDescendants().OfType<ComboBox>().Single(b => AutomationProperties.GetAutomationId(b) == "model-suggestions");
        if (!suggestions.Items.Cast<string>().Contains("a-model") || suggestions.Items.Cast<string>().Count(m => m == "z-model") != 1)
            throw new Exception("Fetched model choices are missing or duplicated");
        var beforeSelection = configured;
        suggestions.SelectedItem = "a-model"; Dispatcher.UIThread.RunJobs();
        if (settings.Provider.Model != "a-model" || configured != beforeSelection + 1) throw new Exception("Model suggestion did not configure its selection");
        Fetch(Reply("unavailable", 503));
        if (!window.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text?.Contains("503") == true)) throw new Exception("Model fetch error was hidden");
        window.Close();
        Console.WriteLine("PASS: API model list endpoint; suggestions configure selection; duplicate models removed; HTTP failure displayed");
    }
}
