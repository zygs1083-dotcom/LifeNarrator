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

public enum ModelProvider: String, Codable, CaseIterable {
    case builtin, openAICompatible, none
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

public enum AppInputError: Error { case invalidURL, missingModel, builtinNotReady }

public struct AppSettings: Codable {
    public var language: InterfaceLanguage = .system
    public var persona: NarratorCore.Persona = .sharp
    public var bubbleStyle = BubbleStyle()
    public var ruleCooldown: TimeInterval = 600
    public var globalPerMinute = 3
    public var minGap: TimeInterval = 5
    public var freeComment = false
    public var paused = false
    public var blacklist = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess", "com.apple.systempreferences", "com.apple.Passwords",
        "com.apple.preferences.passwords"
    ]
    public var disabledBuiltinIds: Set<String> = []
    public var provider: ModelProvider = .none
    public var generationAPI = APIConfiguration()
    public var systemOne: APIConfiguration?
    public var inputShortcut: KeyboardShortcuts.Shortcut? = .init(.n, modifiers: [.option, .shift])
    public var pauseShortcut: KeyboardShortcuts.Shortcut? = .init(.p, modifiers: [.option, .shift])
    public var onboardingCompleted = false
    public init() {}
}

extension BubbleStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case shape, size, theme, textEffects, animation, emojiDensity, font, dwell, maxOnScreen
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
        let fontName = try c.decode(String.self, forKey: .font)
        if fontName == "persona" { font = .persona }
        else { font = .fixed(try value(NarratorFont.self, .font)) }
        dwell = try c.decodeIfPresent(Double.self, forKey: .dwell).map(Dwell.seconds) ?? .untilDismissed
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
    public var rules: URL { root.appendingPathComponent("rules.json") }
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
