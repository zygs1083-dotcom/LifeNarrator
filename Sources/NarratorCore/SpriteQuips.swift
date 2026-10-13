import Foundation

public struct SpriteQuips: Codable, Sendable {
    public var version: Int
    public var categories: [String: [Quip]]

    public static func loadBuiltin() throws -> SpriteQuips {
        let url = Bundle.module.url(forResource: "sprite-quips", withExtension: "json")!
        return try JSONDecoder().decode(SpriteQuips.self, from: Data(contentsOf: url))
    }

    public static func truncate(text: String, lang: Lang) -> String {
        let limit = lang == .zh ? 6 : 12
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    public func rule(for category: String, text: String, app: String, title: String, lang: Lang) -> Rule {
        let value = ["money", "stat", "deadline"].contains(category) && text.count <= 10
            ? text : Self.truncate(text: text, lang: lang)
        return Rule(id: "sprite.\(category).\(stableHash(normalized(text)))", kind: .topic, source: .builtin,
                    label: Label(zh: text, en: text), sentiment: .neutral, match: Match(aliases: [category]),
                    highlight: true, variables: ["text": value, "app": app, "title": title], quips: categories[category]!)
    }
}
