import AppKit
import KeyboardShortcuts
import NarratorCore
import SwiftUI

@MainActor
public final class AppStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet {
            perform { try directory.saveSettings(settings) }
            if oldValue.inputShortcut != settings.inputShortcut || oldValue.pauseShortcut != settings.pauseShortcut {
                registerShortcuts()
            }
            if oldValue.persona != settings.persona || oldValue.bubbleStyle.font != settings.bubbleStyle.font {
                downloadFonts()
            }
        }
    }
    @Published public private(set) var rules: [Rule]
    @Published public var error: String?
    public let builtin: QuipPack
    public let directory: AppDataDirectory
    public let downloader: ModelDownloader
    private var shortcutTasks: [Task<Void, Never>] = []
    private var onboardingWindow: NSWindow?
    private var inputPanel: InputPanelController?

    public init() throws {
        directory = try AppDataDirectory()
        settings = try directory.loadSettings()
        builtin = try RuleLoader.loadBuiltin()
        if FileManager.default.fileExists(atPath: directory.rules.path) {
            rules = try RuleLoader.load(from: directory.rules)
        } else {
            rules = []
            try RuleLoader.save([], to: directory.rules)
        }
        downloader = ModelDownloader(directory: directory)
    }

    public func start() {
        registerShortcuts()
        downloadFonts()
        if !settings.onboardingCompleted {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = text("app.name")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(store: self))
            window.center()
            onboardingWindow = window
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func closeOnboarding() { onboardingWindow!.close() }

    public func text(_ key: String) -> String {
        AppLocalization.string(key, language: settings.language)
    }

    public func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = String(describing: error) }
    }

    public func showInput() {
        if inputPanel == nil { inputPanel = InputPanelController(store: self) }
        inputPanel!.show()
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        var updated = rules
        updated[updated.firstIndex { $0.id == id }!].enabled = enabled
        try saveRules(updated)
    }

    public func deleteRule(id: String) throws { try saveRules(rules.filter { $0.id != id }) }

    private func saveRules(_ updated: [Rule]) throws {
        try RuleLoader.save(updated, to: directory.rules)
        rules = updated
    }

    public func compile(_ input: String) async throws -> Rule {
        let rule: Rule
        switch settings.provider {
        case .none:
            rule = try RuleCompiler.compileWithoutModel(input: input, pack: builtin, now: Date())
        case .openAICompatible:
            let configuration = settings.generationAPI
            let url = try configuration.validatedURL()
            guard !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppInputError.missingModel }
            let client = OpenAICompatibleClient(baseURL: url, model: configuration.model,
                                                key: try KeychainStore.read(account: "generation"))
            rule = try await RuleCompiler.compile(input: input, lang: settings.language.lang, persona: settings.persona,
                                                  now: Date(), generator: client, resolveBundleIds: Self.resolveBundleIds)
        case .builtin:
            throw AppInputError.builtinNotReady
        }
        try saveRules(rules + [rule])
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
                                    persona: Persona(rawValue: settings.persona.rawValue)!)
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
