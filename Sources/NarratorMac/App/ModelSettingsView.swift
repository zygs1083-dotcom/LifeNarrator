import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var store: AppStore
    private let hue = AppTheme.hue(200)
    var body: some View {
        VStack(spacing: 14) {
            GroupBox {
                ProviderSettingsView(store: store)
            } label: { CardHeading(title: store.text("provider"), symbol: "brain.head.profile", hue: hue) }
            GroupBox {
                LabeledContent(store.text("systemOne.enable")) {
                    Toggle(store.text("systemOne.enable"), isOn: Binding(get: { store.settings.systemOne != nil }, set: {
                        store.settings.systemOne = $0 ? APIConfiguration() : nil
                    })).labelsHidden()
                }.frame(minHeight: 28)
                if store.settings.systemOne != nil {
                    APISettingsView(store: store, configuration: Binding(get: { store.settings.systemOne! }, set: {
                        store.settings.systemOne = $0
                    }), account: "systemOne")
                }
            } label: { CardHeading(title: store.text("systemOne"), symbol: "network", hue: hue) }
        }
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ChoiceCards(options: zip(ModelProvider.allCases, ["📦", "☁️", "🚫"]).map {
            (value: $0.0, emoji: $0.1, title: store.text("provider.\($0.0.rawValue)"), caption: store.text("provider.\($0.0.rawValue).hint"))
        }, selection: $store.settings.provider, hue: AppTheme.hue(200))
        switch store.settings.provider {
        case .builtin: ModelDownloadView(store: store, downloader: store.downloader)
        case .openAICompatible: APISettingsView(store: store, configuration: $store.settings.generationAPI, account: "generation")
        case .none: EmptyView()
        }
    }
}

struct ModelDownloadView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloader: ModelDownloader
    @State private var source: ModelDownloadSource = .huggingFace
    var body: some View {
        HStack {
            Text(verbatim: downloader.model.name)
            Spacer()
            switch downloader.state {
            case .notDownloaded: Badge(text: store.text("model.notDownloaded"), hue: AppTheme.hue(42))
            case .downloading: Badge(text: store.text("model.downloading"), hue: AppTheme.hue(200))
            case .verifying: Badge(text: store.text("model.verifying"), hue: AppTheme.hue(42))
            case .ready: Badge(text: store.text("model.ready"), hue: AppTheme.hue(150))
            }
        }.frame(minHeight: 28)
        switch downloader.state {
        case .notDownloaded:
            Picker(store.text("model.source"), selection: $source) {
                ForEach(ModelDownloadSource.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            }.pickerStyle(.menu).tint(AppTheme.accent).frame(minHeight: 28)
            Button(store.text("model.download")) { store.perform { try downloader.start(source: source) } }
                .buttonStyle(AppTheme.CapsuleButton())
        case .downloading(let progress):
            ProgressView(value: progress).tint(AppTheme.accent)
            HStack {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(AppTheme.font(.badge)).monospacedDigit()
                Spacer()
                Button(store.text("model.pause")) {
                    Task {
                        do { try await downloader.pause() }
                        catch { store.error = String(describing: error) }
                    }
                }.buttonStyle(AppTheme.CapsuleButton(filled: false))
            }
        case .verifying:
            ProgressView().controlSize(.small).tint(AppTheme.accent)
        case .ready:
            Button(store.text("delete"), role: .destructive) { store.perform { try downloader.delete() } }
                .buttonStyle(AppTheme.CapsuleButton(hue: AppTheme.hue(350)))
        }
        if let error = downloader.error {
            Badge(text: store.text("error"), hue: AppTheme.hue(350))
            Text(verbatim: error).foregroundStyle(AppTheme.hue(350).text).textSelection(.enabled)
        }
    }
}

struct APISettingsView: View {
    @ObservedObject var store: AppStore
    @Binding var configuration: APIConfiguration
    let account: String
    @State private var key = ""
    @State private var keySaved = false

    var body: some View {
        LabeledContent(store.text("api.baseURL")) {
            TextField(store.text("api.baseURL"), text: $configuration.baseURL, prompt: Text(verbatim: "http://localhost:8080"))
                .textFieldStyle(.roundedBorder)
        }.frame(minHeight: 28)
        LabeledContent(store.text("api.model")) {
            TextField(store.text("api.model"), text: $configuration.model).textFieldStyle(.roundedBorder)
        }.frame(minHeight: 28)
        LabeledContent(store.text("api.key")) {
            SecureField(store.text("api.key"), text: $key).textFieldStyle(.roundedBorder)
                .onChange(of: key) { keySaved = false }
                .onAppear { store.perform { key = try KeychainStore.read(account: account) } }
        }.frame(minHeight: 28)
        HStack {
            Button(store.text("api.saveKey")) {
                store.perform {
                    try KeychainStore.save(key, account: account)
                    keySaved = true
                }
            }.buttonStyle(AppTheme.CapsuleButton())
            if keySaved { Badge(text: store.text("api.keySaved"), hue: AppTheme.hue(150)) }
        }
        if !configuration.baseURL.isEmpty {
            if (try? configuration.validatedURL()) == nil {
                Badge(text: store.text("api.invalidURL"), hue: AppTheme.hue(350))
            } else if configuration.isCloud && store.settings.liveliness != .quiet {
                Badge(text: store.text("api.privacy"), hue: AppTheme.hue(42))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
