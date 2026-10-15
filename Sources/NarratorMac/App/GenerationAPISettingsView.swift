import NarratorCore
import SwiftUI

struct GenerationAPISettingsView: View {
    @ObservedObject var store: AppStore
    @State private var key = ""
    @State private var keySaved = false
    @State private var models: [String] = []
    @State private var busy = false
    @State private var result: String?
    @State private var succeeded = false

    private var preset: ProviderPreset { try! ProviderCatalog.provider(store.settings.generationAPI.presetID) }
    private var configuration: Binding<ProviderConfiguration> { $store.settings.generationAPI }

    var body: some View {
        Picker(store.text("api.provider"), selection: Binding(get: { preset.id }, set: { id in
            store.settings.generationAPI = ProviderConfiguration(presetID: id)
        })) {
            ForEach(ProviderPreset.Group.allCases, id: \.self) { group in
                Section(store.text("api.group.\(group.rawValue)")) {
                    ForEach(ProviderCatalog.providers.filter { $0.group == group }) { provider in
                        Text(store.settings.language.lang == .zh ? provider.name.zh : provider.name.en).tag(provider.id)
                    }
                }
            }
        }.pickerStyle(.menu)
        LabeledContent(store.text("api.model")) {
            TextField(store.text("api.model"), text: configuration.model).textFieldStyle(.roundedBorder)
            if !suggestedModels.isEmpty {
                Menu(store.text("api.suggestions")) {
                    ForEach(suggestedModels, id: \.self) { model in
                        Button(model) { store.settings.generationAPI.model = model }
                    }
                }.fixedSize()
            }
        }
        if preset.modelsEndpoint {
            Button(store.text("api.fetchModels")) { fetchModels() }.disabled(busy)
        }
        if preset.keyRequired || preset.group == .custom {
            LabeledContent(store.text("api.key")) {
                SecureField(store.text("api.key"), text: $key).textFieldStyle(.roundedBorder)
                    .onChange(of: key) { keySaved = false }
                if let keyURL = preset.keyURL { Link(store.text("api.getKey"), destination: keyURL).fixedSize() }
            }
            HStack {
                Button(store.text("api.saveKey")) {
                    store.perform {
                        try store.saveAPIKey(key, account: store.settings.generationAPI.account)
                        keySaved = true
                    }
                }.buttonStyle(AppTheme.CapsuleButton())
                if keySaved { Badge(text: store.text("api.keySaved"), hue: AppTheme.hue(150)) }
            }
        }
        DisclosureGroup(store.text("api.advanced")) {
            LabeledContent(store.text("api.baseURL")) {
                TextField(store.text("api.baseURL"), text: Binding(get: { configuration.wrappedValue.baseURL ?? "" }, set: {
                    configuration.wrappedValue.baseURL = $0.isEmpty ? nil : $0
                }), prompt: Text(verbatim: preset.baseURL.absoluteString)).textFieldStyle(.roundedBorder)
            }
            if preset.api == .openai {
                Picker(store.text("api.structured"), selection: configuration.structured) {
                    Text(store.text("api.default")).tag(Optional<StructuredOutput>.none)
                    ForEach(StructuredOutput.allCases, id: \.self) { mode in
                        Text(verbatim: mode.rawValue).tag(Optional(mode))
                    }
                }.pickerStyle(.menu)
            }
        }
        HStack {
            Button(store.text("api.test")) { testConnection() }.buttonStyle(AppTheme.CapsuleButton()).disabled(busy)
            if busy { ProgressView().controlSize(.small) }
        }
        if let result {
            Text(verbatim: result).foregroundStyle(succeeded ? AppTheme.hue(150).text : AppTheme.hue(350).text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if preset.group != .local {
            Badge(text: store.text("api.privacy"), hue: AppTheme.hue(42)).fixedSize(horizontal: false, vertical: true)
        }
        if (try? store.settings.generationAPI.validatedURL()) == nil {
            Badge(text: store.text("api.invalidURL"), hue: AppTheme.hue(350))
        }
        Color.clear.frame(height: 0).onAppear {
            store.perform { key = try KeychainStore.read(account: store.settings.generationAPI.account) }
        }
    }

    private var suggestedModels: [String] { Array(Set(preset.suggestedModels + models)).sorted() }

    private func fetchModels() {
        let selection = store.settings.generationAPI
        busy = true
        result = nil
        Task {
            defer { busy = false }
            do { models = try await selection.fetchModels(key: key) }
            catch { succeeded = false; result = String(describing: error) }
        }
    }

    private func testConnection() {
        let selection = store.settings.generationAPI
        busy = true
        result = nil
        Task {
            defer { busy = false }
            do {
                let generator = try selection.generator(key: key)
                let start = ContinuousClock.now
                let json = try await generator.generateJSON(system: nil, prompt: "Return JSON with ok set to true.",
                    schema: #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#, maxTokens: 1024)
                struct Reply: Decodable { let ok: Bool }
                guard try JSONDecoder().decode(Reply.self, from: Data(json.utf8)).ok else { throw ProviderConfigurationError.invalidResponse }
                let elapsed = start.duration(to: .now)
                let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                succeeded = true
                result = "\(store.text("api.testSuccess")) · \(ms) ms"
            } catch { succeeded = false; result = String(describing: error) }
        }
    }
}
