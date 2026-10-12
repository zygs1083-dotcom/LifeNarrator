import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum Persona: String, Codable, CaseIterable, Sendable { case sharp, gentle, chuuni }
public enum Lang: String, Codable, CaseIterable, Sendable { case zh, en }
public enum RuleKind: String, Codable, Sendable { case app, site, person, topic, time }
public enum Sentiment: String, Codable, Sendable { case dislike, like, neutral }
public enum RuleSource: String, Codable, Sendable { case user, builtin }
public enum Region: String, Codable, Sendable { case header, anywhere }
public enum TextSource: String, Codable, Sendable { case ax, ocr, none }
public enum When: String, Codable, Sendable {
    case any, lateNight, mondayMorning, fridayEvening

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        switch self {
        case .any: return true
        case .lateNight: return hour >= 23 || hour < 5
        case .mondayMorning: return weekday == 2 && (6..<11).contains(hour)
        case .fridayEvening: return weekday == 6 && (16..<20).contains(hour)
        }
    }

    public static func current(at date: Date, calendar: Calendar = .current) -> When {
        [.lateNight, .mondayMorning, .fridayEvening].first { $0.contains(date, calendar: calendar) } ?? .any
    }
}

public struct Label: Codable, Equatable, Sendable {
    public var zh: String
    public var en: String
    public init(zh: String, en: String) { self.zh = zh; self.en = en }
    public subscript(lang: Lang) -> String { lang == .zh ? zh : en }
}

public struct Match: Codable, Equatable, Sendable {
    public var bundleIds: [String]?
    public var appNames: [String]?
    public var domains: [String]?
    public var aliases: [String]?
    public var region: Region?
    public var when: When?
    public init(bundleIds: [String]? = nil, appNames: [String]? = nil, domains: [String]? = nil,
                aliases: [String]? = nil, region: Region? = nil, when: When? = nil) {
        self.bundleIds = bundleIds; self.appNames = appNames; self.domains = domains
        self.aliases = aliases; self.region = region; self.when = when
    }
}

public struct Quip: Codable, Equatable, Hashable, Sendable {
    public var lang: Lang
    public var persona: Persona
    public var text: String
    public var emoji: [String]
    public var when: When
    public init(lang: Lang, persona: Persona, text: String, emoji: [String] = [], when: When = .any) {
        self.lang = lang; self.persona = persona; self.text = text; self.emoji = emoji; self.when = when
    }
    enum CodingKeys: String, CodingKey { case lang, persona, text, emoji, when }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lang = try c.decode(Lang.self, forKey: .lang)
        persona = try c.decode(Persona.self, forKey: .persona)
        text = try c.decode(String.self, forKey: .text)
        emoji = try c.decodeIfPresent([String].self, forKey: .emoji) ?? []
        when = try c.decodeIfPresent(When.self, forKey: .when) ?? .any
    }
}

public struct Rule: Codable, Equatable, Sendable {
    public var id: String
    public var kind: RuleKind
    public var source: RuleSource
    public var enabled: Bool
    public var input: String?
    public var label: Label
    public var sentiment: Sentiment
    public var note: String?
    public var match: Match
    public var highlight: Bool
    public var variables: [String: String]?
    public var quips: [Quip]
    public var createdAt: Date?
    public init(id: String, kind: RuleKind, source: RuleSource, enabled: Bool = true, input: String? = nil,
                label: Label, sentiment: Sentiment, note: String? = nil, match: Match,
                highlight: Bool, variables: [String: String]? = nil, quips: [Quip] = [], createdAt: Date? = nil) {
        self.id = id; self.kind = kind; self.source = source; self.enabled = enabled; self.input = input
        self.label = label; self.sentiment = sentiment; self.note = note; self.match = match
        self.highlight = highlight; self.variables = variables; self.quips = quips; self.createdAt = createdAt
    }
}

public struct TextLine: Codable, Equatable, Sendable {
    public var text: String
    public var rect: CGRect
    public init(text: String, rect: CGRect) { self.text = text; self.rect = rect }
}

public struct ContextSnapshot: Codable, Sendable {
    public var bundleId: String
    public var appName: String
    public var pid: Int32
    public var windowTitle: String?
    public var windowFrame: CGRect
    public var contentFrame: CGRect
    public var screenIndex: Int
    public var url: String?
    public var host: String?
    public var textLines: [TextLine]
    public var textSource: TextSource
    public var capturedAt: Date
    public init(bundleId: String, appName: String, pid: Int32, windowTitle: String? = nil,
                windowFrame: CGRect, contentFrame: CGRect, screenIndex: Int = 0, url: String? = nil,
                host: String? = nil, textLines: [TextLine] = [], textSource: TextSource = .none, capturedAt: Date) {
        self.bundleId = bundleId; self.appName = appName; self.pid = pid; self.windowTitle = windowTitle
        self.windowFrame = windowFrame; self.contentFrame = contentFrame; self.screenIndex = screenIndex
        self.url = url; self.host = host; self.textLines = textLines; self.textSource = textSource
        self.capturedAt = capturedAt
    }
}
