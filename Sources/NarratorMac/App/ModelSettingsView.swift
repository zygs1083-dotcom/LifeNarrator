import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Form {
            ProviderSettingsView(store: store)
            Section(store.text("systemOne")) {
                Toggle(store.text("systemOne.enable"), isOn: Binding(get: { store.settings.systemOne != nil }, set: {
                    store.settings.systemOne = $0 ? APIConfiguration() : nil
                }))
                if store.settings.systemOne != nil {
                    APISettingsView(store: store, configuration: Binding(get: { store.settings.systemOne! }, set: {
                        store.settings.systemOne = $0
                    }), account: "systemOne")
                }
            }
        }.formStyle(.grouped)
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Picker(store.text("provider"), selection: $store.settings.provider) {
            ForEach(ModelProvider.allCases, id: \.self) { value in
                Text(store.text("provider.\(value.rawValue)")).tag(value)
            }
        }
        switch store.settings.provider {
        case .builtin: ModelDownloadView(store: store, downloader: store.downloader)
        case .openAICompatible: APISettingsView(store: store, configuration: $store.settings.generationAPI, account: "generation")
        case .none: Text(store.text("provider.none.hint")).foregroundStyle(.secondary)
        }
    }
}

struct ModelDownloadView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloader: ModelDownloader
    @State private var source: ModelDownloadSource = .huggingFace
    var body: some View {
        Text(verbatim: downloader.model.name)
        switch downloader.state {
        case .notDownloaded:
            Text(store.text("model.notDownloaded"))
            Picker(store.text("model.source"), selection: $source) {
                ForEach(ModelDownloadSource.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            }
            Button(store.text("model.download")) { store.perform { try downloader.start(source: source) } }
        case .downloading(let progress):
            ProgressView(value: progress) { Text(store.text("model.downloading")) }
            Text(progress, format: .percent.precision(.fractionLength(0)))
            Button(store.text("model.pause")) {
                Task {
                    do { try await downloader.pause() }
                    catch { store.error = String(describing: error) }
                }
            }
        case .verifying:
            ProgressView { Text(store.text("model.verifying")) }
        case .ready:
            Label(store.text("model.ready"), systemImage: "checkmark.circle")
            Button(store.text("delete"), role: .destructive) { store.perform { try downloader.delete() } }
        }
        if let error = downloader.error { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
    }
}

struct APISettingsView: View {
    @ObservedObject var store: AppStore
    @Binding var configuration: APIConfiguration
    let account: String
    @State private var key = ""
    @State private var keySaved = false

    var body: some View {
        TextField(store.text("api.baseURL"), text: $configuration.baseURL, prompt: Text(verbatim: "http://localhost:8080"))
        TextField(store.text("api.model"), text: $configuration.model)
        SecureField(store.text("api.key"), text: $key)
            .onChange(of: key) { keySaved = false }
            .onAppear { store.perform { key = try KeychainStore.read(account: account) } }
        HStack {
            Button(store.text("api.saveKey")) {
                store.perform {
                    try KeychainStore.save(key, account: account)
                    keySaved = true
                }
            }
            if keySaved { Label(store.text("api.keySaved"), systemImage: "checkmark") }
        }
        if !configuration.baseURL.isEmpty {
            if (try? configuration.validatedURL()) == nil {
                Text(store.text("api.invalidURL")).foregroundStyle(.red)
            } else if configuration.isCloud {
                Label(store.text("api.privacy"), systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }

    }
}
