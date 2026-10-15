import AppKit
import Combine
import KeyboardShortcuts
import NarratorCore
import SwiftUI

@MainActor
public final class AppStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet {
            perform { try directory.saveSettings(settings) }
            if oldValue.language != settings.language {
                onboardingWindow?.title = text("app.name")
                settingsWindow?.title = text("app.name")
            }
            if oldValue.inputShortcut != settings.inputShortcut || oldValue.pauseShortcut != settings.pauseShortcut {
                registerShortcuts()
            }
            if oldValue.persona != settings.persona || oldValue.bubbleStyle.font != settings.bubbleStyle.font {
                downloadFonts()
            }
            if oldValue.persona != settings.persona || oldValue.language != settings.language { pregenerator.schedule() }
            engine?.configure()
        }
    }
    @Published public private(set) var personas: PersonaCatalog
    @Published public private(set) var rules: [Rule]
    @Published public var error: String?
    @Published public private(set) var screenRecordingGranted = ContextPermissions.isGranted(.screenCapture)
    public var said: SaidHistory
    public let builtin: QuipPack
    public let directory: AppDataDirectory
    public let downloader: ModelDownloader
    private var shortcutTasks: [Task<Void, Never>] = []
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var inputPanel: InputPanelController?
    private var engine: NarratorEngine?
    private var downloadSubscription: AnyCancellable?
    private lazy var pregenerator = QuipPregenerator(store: self)
    private lazy var llama = LlamaGenerator(modelPath: downloader.destination.path)

    public init() throws {
        directory = try AppDataDirectory()
        settings = try directory.loadSettings()
        personas = try PersonaCatalog.load(from: directory.personas)
        builtin = try RuleLoader.loadBuiltin()
        said = FileManager.default.fileExists(atPath: directory.said.path)
            ? try JSONDecoder().decode(SaidHistory.self, from: Data(contentsOf: directory.said)) : SaidHistory()
        if FileManager.default.fileExists(atPath: directory.rules.path) {
            rules = try RuleLoader.load(from: directory.rules)
        } else {
            rules = []
            try RuleLoader.save([], to: directory.rules)
        }
        downloader = ModelDownloader(directory: directory)
        downloadSubscription = downloader.$state.dropFirst().sink { [unowned self] state in
            self.objectWillChange.send()
            if case .ready = state { self.pregenerator.schedule() }
        }
    }

    public func recordSaid(_ text: String, now: Date) throws {
        said.record(text, now: now)
        try JSONEncoder().encode(said).write(to: directory.said, options: .atomic)
    }

    public func start() {
        refreshScreenRecordingPermission()
        registerShortcuts()
        downloadFonts()
        if !settings.onboardingCompleted {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = text("app.name")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(store: self))
            window.center()
            onboardingWindow = window
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            startEngine()
        }
    }

    public func closeOnboarding() {
        onboardingWindow!.close()
        startEngine()
    }

    private func startEngine() {
        guard ContextPermissions.isGranted(.accessibility) else {
            // Each new build has a new ad-hoc signature, so an update loses the grant: ask, then start once granted.
            ContextPermissions.request(.accessibility)
            Task {
                while !ContextPermissions.isGranted(.accessibility) { try await Task.sleep(for: .seconds(2)) }
                startEngine()
            }
            return
        }
        perform {
            engine = try NarratorEngine(store: self)
            try engine!.start()
        }
    }

    public func text(_ key: String) -> String {
        AppLocalization.string(key, language: settings.language)
    }

    public func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = String(describing: error) }
    }

    // An AppKit window rather than a SwiftUI Settings scene so it can also open when the app is
    // launched again, the only way in when macOS hides the menu bar icon (a full menu bar on a notched Mac).
    public func showSettings() {
        refreshScreenRecordingPermission()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = text("app.name")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppSettingsView(store: self))
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow!.makeKeyAndOrderFront(nil)
    }

    private func refreshScreenRecordingPermission() {
        screenRecordingGranted = ContextPermissions.isGranted(.screenCapture)
        if ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[sprite] screen-recording granted=\(screenRecordingGranted)\n".utf8))
        }
    }

    func openScreenRecordingSettings() {
        ContextPermissions.request(.screenCapture)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func relaunch() {
        Task {
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                NSApp.terminate(nil)
            } catch { self.error = String(describing: error) }
        }
    }

    public func showInput() {
        if inputPanel == nil { inputPanel = InputPanelController(store: self) }
        inputPanel!.show()
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        var updated = rules
        updated[updated.firstIndex { $0.id == id }!].enabled = enabled
        try saveRules(updated)
        if enabled { pregenerator.schedule() }
    }

    public func deleteRule(id: String) throws { try saveRules(rules.filter { $0.id != id }) }

    func update(_ rule: Rule) throws {
        var updated = rules
        updated[updated.firstIndex { $0.id == rule.id }!] = rule
        try saveRules(updated)
    }

    private func saveRules(_ updated: [Rule]) throws {
        try RuleLoader.save(updated, to: directory.rules)
        rules = updated
        engine?.configure()
    }

    public func releaseModel() async {
        await llama.close()
    }

    public func textGenerator() throws -> (any TextGenerator)? {
        switch settings.provider {
        case .none: return nil
        case .builtin:
            if case .ready = downloader.state { return llama }
            return nil
        case .openAICompatible:
            let configuration = settings.generationAPI
            let url = try configuration.validatedURL()
            guard !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppInputError.missingModel }
            return OpenAICompatibleClient(baseURL: url, model: configuration.model,
                                          key: try KeychainStore.read(account: "generation"))
        }
    }

    public var personaModelUnavailableReason: String? {
        switch settings.provider {
        case .none: return text("persona.custom.noModel")
        case .builtin:
            if case .ready = downloader.state { return nil }
            return text("persona.custom.downloadModel")
        case .openAICompatible:
            do {
                _ = try settings.generationAPI.validatedURL()
                guard !settings.generationAPI.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return text("persona.custom.configureModel")
                }
                return nil
            } catch { return text("persona.custom.configureModel") }
        }
    }

    public func createPersona(_ input: String) async throws {
        guard let generator = try textGenerator() else { throw AppInputError.missingModel }
        let profile = try await PersonaGenerator.generate(input: input, generator: generator)
        let updated = PersonaCatalog(custom: personas.custom + [profile])
        try updated.save(to: directory.personas)
        personas = updated
        settings.persona = profile.id
    }

    public func deletePersona(_ id: Persona) throws {
        if settings.persona == id { settings.persona = .sharp }
        let updated = PersonaCatalog(custom: personas.custom.filter { $0.id != id })
        try updated.save(to: directory.personas)
        personas = updated
        engine?.configure()
    }

    public func compile(_ input: String, generator: (any TextGenerator)?) async throws -> Rule {
        let rule: Rule
        if let generator {
            rule = try await RuleCompiler.compile(input: input, lang: settings.language.lang, now: Date(),
                                                  generator: generator, resolveBundleIds: Self.resolveBundleIds)
        } else {
            rule = try RuleCompiler.compileWithoutModel(input: input, pack: builtin, now: Date())
        }
        try saveRules(rules + [rule])
        pregenerator.schedule()
        return rule
    }

    private func registerShortcuts() {
        shortcutTasks.forEach { $0.cancel() }
        shortcutTasks = []
        if let shortcut = settings.inputShortcut {
            shortcutTasks.append(Task { [weak self] in
                for await event in KeyboardShortcuts.events(for: shortcut) where event == .keyUp {
                    self?.showInput()
                }
            })
        }
        if let shortcut = settings.pauseShortcut {
            shortcutTasks.append(Task { [weak self] in
                for await event in KeyboardShortcuts.events(for: shortcut) where event == .keyUp {
                    self?.settings.paused.toggle()
                }
            })
        }
    }

    private func downloadFonts() {
        BubbleFonts.requestDownload(choice: settings.bubbleStyle.font,
                                    persona: settings.persona, catalog: personas)
    }

    nonisolated private static func resolveBundleIds(_ names: [String]) throws -> [String] {
        let directories = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var ids: [String] = []
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            let apps = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
            while let url = apps.nextObject() as? URL {
                guard url.pathExtension == "app" else { continue }
                apps.skipDescendants()
                let bundle = Bundle(url: url)!
                let appNames = [url.deletingPathExtension().lastPathComponent,
                                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap { $0 }
                if names.contains(where: { name in appNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }),
                   let id = bundle.bundleIdentifier { ids.append(id) }
            }
        }
        return Array(Set(ids)).sorted()
    }
}
