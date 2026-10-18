import Foundation
import KeyboardShortcuts
import NarratorCore

public enum InterfaceLanguage: String, Codable, CaseIterable {
    case system, en, zhHans

    public var lang: Lang {
        switch self {
        case .en: .en
        case .zhHans: .zh
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
        }
    }
}

public struct APIConfiguration: Codable {
    public var baseURL = ""
    public var model = ""
    public init() {}

    public func validatedURL() throws -> URL {
        guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme), url.host != nil else {
            throw AppInputError.invalidURL
        }
        return url
    }

    public var isCloud: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

public enum AppInputError: Error { case invalidURL, missingModel, unknownBuiltinModel(String) }

public struct AppSettings: Codable {
    public var language: InterfaceLanguage = .system
    public var persona: Persona = .sharp
    public var bubbleStyle = BubbleStyle()
    public var liveliness: Liveliness = .lively
    public var markGap: Double = 2
    public var memoryEnabled = true
    public var spriteName = ""
    public var paused = false
    public var blacklist = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess", "com.apple.systempreferences", "com.apple.Passwords",
        "com.apple.preferences.passwords", "com.apple.SecurityAgent", "com.apple.loginwindow",
        "com.apple.LocalAuthentication.UIAgent"
    ]
    public var disabledBuiltinIds: Set<String> = []
    public var provider: ModelProvider = .builtin
    public var generationAPI = ProviderConfiguration()
    public var builtinModel = ModelCatalog.models[0].name
    public var systemOne: APIConfiguration?
    public var inputShortcut: KeyboardShortcuts.Shortcut? = .init(.n, modifiers: [.option, .shift])
    public var chatShortcut: KeyboardShortcuts.Shortcut? = .init(.space, modifiers: [.option, .shift])
    public var pauseShortcut: KeyboardShortcuts.Shortcut? = .init(.p, modifiers: [.option, .shift])
    public var automaticUpdates = true
    public var seenAnnouncementVersion: String?
    public var onboardingCompleted = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case seenAnnouncementVersion, spriteName, chatShortcut, memoryEnabled, builtinModel, language, persona, bubbleStyle, paused, blacklist, disabledBuiltinIds, provider, generationAPI, systemOne, inputShortcut, pauseShortcut, onboardingCompleted, liveliness, markGap, automaticUpdates
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(seenAnnouncementVersion, forKey: .seenAnnouncementVersion)
        try c.encode(language, forKey: .language)
        try c.encode(persona, forKey: .persona)
        try c.encode(bubbleStyle, forKey: .bubbleStyle)
        try c.encode(liveliness, forKey: .liveliness)
        try c.encode(markGap, forKey: .markGap)
        try c.encode(memoryEnabled, forKey: .memoryEnabled)
        try c.encode(paused, forKey: .paused)
        try c.encode(blacklist, forKey: .blacklist)
        try c.encode(disabledBuiltinIds, forKey: .disabledBuiltinIds)
        try c.encode(provider, forKey: .provider)
        try c.encode(generationAPI, forKey: .generationAPI)
        try c.encode(builtinModel, forKey: .builtinModel)
        try c.encodeIfPresent(systemOne, forKey: .systemOne)
        try c.encodeIfPresent(inputShortcut, forKey: .inputShortcut)
        try c.encodeIfPresent(pauseShortcut, forKey: .pauseShortcut)
        try c.encode(chatShortcut, forKey: .chatShortcut)
        try c.encode(spriteName, forKey: .spriteName)
        try c.encode(automaticUpdates, forKey: .automaticUpdates)
        try c.encode(onboardingCompleted, forKey: .onboardingCompleted)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.chatShortcut) { chatShortcut = try c.decodeIfPresent(KeyboardShortcuts.Shortcut.self, forKey: .chatShortcut) }
        seenAnnouncementVersion = try c.decodeIfPresent(String.self, forKey: .seenAnnouncementVersion)
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        spriteName = try c.decodeIfPresent(String.self, forKey: .spriteName) ?? ""
        automaticUpdates = try c.decodeIfPresent(Bool.self, forKey: .automaticUpdates) ?? true
        liveliness = try c.decodeIfPresent(Liveliness.self, forKey: .liveliness) ?? .lively
        markGap = try c.decodeIfPresent(Double.self, forKey: .markGap) ?? 2
        language = try c.decode(InterfaceLanguage.self, forKey: .language)
        persona = try c.decode(Persona.self, forKey: .persona)
        bubbleStyle = try c.decode(BubbleStyle.self, forKey: .bubbleStyle)
        paused = try c.decode(Bool.self, forKey: .paused)
        blacklist = try c.decode([String].self, forKey: .blacklist)
        disabledBuiltinIds = try c.decode(Set<String>.self, forKey: .disabledBuiltinIds)
        provider = try c.decode(ModelProvider.self, forKey: .provider)
        generationAPI = try c.decode(ProviderConfiguration.self, forKey: .generationAPI)
        builtinModel = try c.decodeIfPresent(String.self, forKey: .builtinModel) ?? ModelCatalog.models[0].name
        guard ModelCatalog.models.contains(where: { $0.name == builtinModel }) else { throw AppInputError.unknownBuiltinModel(builtinModel) }
        systemOne = try c.decodeIfPresent(APIConfiguration.self, forKey: .systemOne)
        inputShortcut = try c.decodeIfPresent(KeyboardShortcuts.Shortcut.self, forKey: .inputShortcut)
        pauseShortcut = try c.decodeIfPresent(KeyboardShortcuts.Shortcut.self, forKey: .pauseShortcut)
        onboardingCompleted = try c.decode(Bool.self, forKey: .onboardingCompleted)
    }
}

extension BubbleStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case shape, size, theme, textEffects, animation, emojiDensity, emoji, font, dwell, maxOnScreen
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: RawRepresentable>(_ type: T.Type, _ key: CodingKeys) throws -> T where T.RawValue == String {
            let raw = try c.decode(String.self, forKey: key)
            guard let value = T(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Unknown value: \(raw)")
            }
            return value
        }
        shape = try value(BubbleShape.self, .shape)
        size = try value(BubbleSize.self, .size)
        theme = try value(ColorTheme.self, .theme)
        textEffects = TextEffects(rawValue: try c.decode(Int.self, forKey: .textEffects))
        animation = try value(BubbleAnimation.self, .animation)
        emojiDensity = try value(EmojiDensity.self, .emojiDensity)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        let fontName = try c.decode(String.self, forKey: .font)
        if fontName == "persona" { font = .persona }
        else { font = .fixed(try value(NarratorFont.self, .font)) }
        dwell = try c.decodeIfPresent(Double.self, forKey: .dwell).map { .seconds(min(max($0, 1), 30)) } ?? .untilDismissed
        maxOnScreen = try c.decode(Int.self, forKey: .maxOnScreen)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape.rawValue, forKey: .shape)
        try c.encode(size.rawValue, forKey: .size)
        try c.encode(theme.rawValue, forKey: .theme)
        try c.encode(textEffects.rawValue, forKey: .textEffects)
        try c.encode(animation.rawValue, forKey: .animation)
        try c.encode(emojiDensity.rawValue, forKey: .emojiDensity)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        switch font {
        case .persona: try c.encode("persona", forKey: .font)
        case .fixed(let font): try c.encode(font.rawValue, forKey: .font)
        }
        switch dwell {
        case .seconds(let seconds): try c.encode(seconds, forKey: .dwell)
        case .untilDismissed: try c.encodeNil(forKey: .dwell)
        }
        try c.encode(maxOnScreen, forKey: .maxOnScreen)
    }
}

public struct AppDataDirectory {
    public let root: URL
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var personas: URL { root.appendingPathComponent("personas.json") }
    public var rules: URL { root.appendingPathComponent("rules.json") }
    public var said: URL { root.appendingPathComponent("said.json") }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let path = environment["LIFENARRATOR_DATA_DIR"] {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/LifeNarrator", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    }

    public func loadSettings() throws -> AppSettings {
        if !FileManager.default.fileExists(atPath: settings.path) {
            let value = AppSettings()
            try saveSettings(value)
            return value
        }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settings))
    }

    public func saveSettings(_ value: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: settings, options: .atomic)
    }
}
