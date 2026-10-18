import AppKit
import Combine
import KeyboardShortcuts
import NarratorCore
import NarratorBrain
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
            if oldValue.inputShortcut != settings.inputShortcut || oldValue.pauseShortcut != settings.pauseShortcut || oldValue.chatShortcut != settings.chatShortcut {
                registerShortcuts()
            }
            if oldValue.persona != settings.persona || oldValue.bubbleStyle.font != settings.bubbleStyle.font {
                downloadFonts()
            }
            if oldValue.persona != settings.persona || oldValue.language != settings.language { pregenerator.schedule() }
            if oldValue.automaticUpdates != settings.automaticUpdates { updater.configure(automatic: settings.automaticUpdates) }
            if oldValue.builtinModel != settings.builtinModel || oldValue.provider != settings.provider {
                if let previous = llama {
                    let pending = modelRelease
                    modelRelease = Task { await pending?.value; await previous.close() }
                }
                llama = nil
            }
            engine?.configure()
        }
    }
    @Published public private(set) var personas: PersonaCatalog
    @Published public private(set) var rules: [Rule]
    @Published public var error: String?
    @Published public private(set) var screenRecordingGranted = ContextPermissions.isGranted(.screenCapture)
    public let builtin: QuipPack
    public let directory: AppDataDirectory
    public let updater = Updater()
    public let downloaders: [ModelDownloader]
    public var downloader: ModelDownloader { downloaders.first { $0.model.name == settings.builtinModel }! }
    private var shortcutTasks: [Task<Void, Never>] = []
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var announcementWindow: AnnouncementWindow?
    private var chatPanel: ChatPanelController?
    private var inputPanel: InputPanelController?
    private var engine: NarratorEngine?
    private var downloadSubscriptions: [AnyCancellable] = []
    private lazy var pregenerator = QuipPregenerator(store: self)
    private var llama: LlamaGenerator?
    private var modelRelease: Task<Void, Never>?

    public init() throws {
        let directory = try AppDataDirectory()
        self.directory = directory
        settings = try directory.loadSettings()
        personas = try PersonaCatalog.load(from: directory.personas)
        try KeychainStore.migrateGenerationKey()
        builtin = try RuleLoader.loadBuiltin()
        if FileManager.default.fileExists(atPath: directory.rules.path) {
            rules = try RuleLoader.load(from: directory.rules)
        } else {
            rules = []
            try RuleLoader.save([], to: directory.rules)
        }
        downloaders = ModelCatalog.models.map { ModelDownloader(directory: directory, model: $0) }
        downloadSubscriptions = downloaders.map { downloader in
            downloader.$state.dropFirst().receive(on: DispatchQueue.main).sink { [unowned self, unowned downloader] state in
                self.objectWillChange.send()
                switch state {
                case .ready, .notDownloaded:
                    if self.settings.provider == .builtin && self.downloader === downloader { self.engine?.configure() }
                case .downloading, .verifying: break
                }
                if case .ready = state { self.pregenerator.schedule() }
            }
        }
        // Memory settings remain available before accessibility permission is granted.
        engine = try NarratorEngine(store: self)
        engine!.configure()
    }

    public func start() {
        updater.configure(automatic: settings.automaticUpdates)
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
            showAnnouncementIfNeeded()
            startEngine()
        }
    }

    public func closeOnboarding() {
        onboardingWindow!.close()
        showAnnouncementIfNeeded()
        startEngine()
    }

    private func showAnnouncementIfNeeded() {
        if UpdateAnnouncement.shouldShow(onboardingCompleted: settings.onboardingCompleted,
                                         seenVersion: settings.seenAnnouncementVersion) { showAnnouncement() }
    }

    func showAnnouncement() {
        guard settings.onboardingCompleted else { return }
        perform {
            let announcement = try UpdateAnnouncement.load()
            if announcementWindow == nil {
                let window = AnnouncementWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.minSize = NSSize(width: 320, height: 260)
                window.onClose = { [weak self] in self?.settings.seenAnnouncementVersion = NarratorCore.version }
                window.contentView = NSHostingView(rootView: AnnouncementView(store: self, announcement: announcement,
                    dismiss: { [weak window] in window?.close() }))
                window.center()
                announcementWindow = window
            }
            let window = announcementWindow!
            window.title = announcement.title.value(settings.language.lang)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
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

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func copyScreenRecordingResetCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("tccutil reset ScreenCapture dev.lifenarrator.app", forType: .string)
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
                // Not inline: terminate waits for applicationShouldTerminate's reply on the main actor, which is busy
                // running this task, so the app would hang. A run loop timer calls it once this task has returned.
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            } catch { self.error = String(describing: error) }
        }
    }

    public func showInput() {
        if inputPanel == nil { inputPanel = InputPanelController(store: self) }
        inputPanel!.show()
    }

    public func showChat(narration: String? = nil, near frame: CGRect? = nil) {
        guard let engine else { return }
        Task {
            do {
                let context = try await engine.chatContext(narration: narration)
                if chatPanel == nil { chatPanel = ChatPanelController(store: self) }
                chatPanel!.show(context: context, near: frame)
            } catch { self.error = String(describing: error) }
        }
    }

    var chatTurns: [ChatTurn] { engine!.chatTurns }

    func sendChat(_ input: String, context: ChatContext, includeScreen: Bool) async throws -> ChatTurn {
        try await engine!.sendChat(input, context: context, includeScreen: includeScreen)
    }

    public var memories: [Memory] { engine?.memories ?? [] }
    public var growthState: GrowthState? { engine?.growthState }
    public func isUnlocked(_ unlock: GrowthUnlock) -> Bool {
        growthState?.unlocked.contains(unlock) == true
    }

    public var spriteDisplayName: String {
        let name = settings.spriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return isUnlocked(.spriteName) && !name.isEmpty ? name : text("tab.sprite")
    }

    @discardableResult
    public func addMemory(kind: Memory.Kind, text: String) throws -> Memory? {
        try engine!.addMemory(kind: kind, text: text)
    }

    public func editMemory(id: UUID, kind: Memory.Kind, text: String) throws {
        try engine!.editMemory(id: id, kind: kind, text: text)
    }

    public func pinMemory(id: UUID, pinned: Bool) throws { try engine!.pinMemory(id: id, pinned: pinned) }
    public func deleteMemory(id: UUID) throws { try engine!.deleteMemory(id: id) }
    public func clearMemories() throws { try engine!.clearMemories() }

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
        await llama?.close()
        await modelRelease?.value
        llama = nil
    }

    func saveAPIKey(_ key: String, account: String) throws {
        try KeychainStore.save(key, account: account)
        engine?.configure()
    }

    public func textGenerator() throws -> (any TextGenerator)? {
        switch settings.provider {
        case .none: return nil
        case .builtin:
            if case .ready = downloader.state {
                if llama == nil { llama = LlamaGenerator(modelPath: downloader.destination.path, waitForRelease: modelRelease) }
                return llama
            }
            return nil
        case .api:
            let configuration = settings.generationAPI
            return try configuration.generator(key: KeychainStore.read(account: configuration.account))
        }
    }

    public var personaModelUnavailableReason: String? {
        switch settings.provider {
        case .none: return text("persona.custom.noModel")
        case .builtin:
            if case .ready = downloader.state { return nil }
            return text("persona.custom.downloadModel")
        case .api:
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
        try engine?.recordGrowth(.rule)
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
        if let shortcut = settings.chatShortcut {
            shortcutTasks.append(Task { [weak self] in
                for await event in KeyboardShortcuts.events(for: shortcut) where event == .keyUp {
                    self?.showChat()
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
