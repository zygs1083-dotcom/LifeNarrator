import Foundation

public struct PersonaProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: Persona
    public var emoji: String
    public var name: Label
    public var caption: Label
    public var description: Label
    public var focus: Label?
    public var limit: Limit
    public var fonts: Fonts
    public var pack: Persona
    public var examples: Persona

    public struct Limit: Codable, Equatable, Sendable {
        public var zh: Int
        public var en: Int
        public subscript(lang: Lang) -> Int { lang == .zh ? zh : en }
    }

    public struct Fonts: Codable, Equatable, Sendable {
        public var zh: [String]
        public var en: [String]
        public subscript(lang: Lang) -> [String] { lang == .zh ? zh : en }
    }
}

public struct PersonaCatalog: Sendable {
    public static let builtin: PersonaCatalog = {
        let url = Bundle.module.url(forResource: "personas", withExtension: "json")!
        return try! PersonaCatalog(profiles: JSONDecoder().decode([PersonaProfile].self, from: Data(contentsOf: url)))
    }()

    public let profiles: [PersonaProfile]
    public var custom: [PersonaProfile] { profiles.filter { $0.id.rawValue.hasPrefix("custom.") } }

    private init(profiles: [PersonaProfile]) { self.profiles = profiles }

    public init(custom: [PersonaProfile] = []) {
        profiles = Self.builtin.profiles + custom
    }

    public subscript(persona: Persona) -> PersonaProfile {
        profiles.first { $0.id == persona }!
    }

    public static func load(from url: URL) throws -> PersonaCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else { return .builtin }
        let custom = try JSONDecoder().decode([PersonaProfile].self, from: Data(contentsOf: url))
        guard Set(custom.map(\.id)).count == custom.count,
              custom.allSatisfy({ $0.id.rawValue.hasPrefix("custom.") && [.sharp, .gentle, .chuuni].contains($0.pack)
                  && [.sharp, .gentle, .chuuni].contains($0.examples) && $0.limit.zh == 14 && $0.limit.en == 8 }) else {
            throw PersonaGenerationError.invalidProfile
        }
        return PersonaCatalog(custom: custom)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(custom).write(to: url, options: .atomic)
    }
}

public enum PersonaGenerationError: Error { case invalidProfile }

public enum PersonaGenerator {
    public static let schema = #"""
    {
      "type": "object", "required": ["name", "emoji", "description", "pack"], "additionalProperties": false,
      "properties": {
        "name": {"type": "object", "required": ["zh", "en"], "properties": {"zh": {"type": "string"}, "en": {"type": "string"}}},
        "emoji": {"type": "string"},
        "description": {"type": "object", "required": ["zh", "en"], "properties": {"zh": {"type": "string"}, "en": {"type": "string"}}},
        "focus": {"type": "object", "required": ["zh", "en"], "properties": {"zh": {"type": "string"}, "en": {"type": "string"}}},
        "pack": {"enum": ["sharp", "gentle", "chuuni"]}
      }
    }
    """#

    public static func generate(input: String, generator: any TextGenerator) async throws -> PersonaProfile {
        struct Draft: Decodable {
            var name: Label
            var emoji: String
            var description: Label
            var focus: Label?
            var pack: Persona
        }
        let system = """
        Create a LifeNarrator persona from the user's sentence. Output JSON only, in this order:
        name: {zh, en}, a short display name in Chinese and English;
        emoji: one emoji;
        description: {zh, en}, a concise character description in both languages;
        optional focus: {zh, en}, which screen details to prioritize, only if relevant;
        pack: sharp, gentle or chuuni, the closest offline voice.
        Be cute and specific, never cruel or preachy. Do not attack looks, intelligence, family or identity.
        """
        let json = try await generator.generateJSON(system: system, prompt: input, schema: schema)
        let draft = try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
        guard [.sharp, .gentle, .chuuni].contains(draft.pack), draft.emoji.count == 1,
              QuipValidator.isEmoji(draft.emoji.first!),
              !draft.name.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.name.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.description.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.description.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersonaGenerationError.invalidProfile
        }
        let base = PersonaCatalog.builtin[draft.pack]
        return PersonaProfile(id: Persona(rawValue: "custom." + UUID().uuidString.lowercased()), emoji: draft.emoji,
            name: draft.name, caption: Label(zh: input, en: input), description: draft.description, focus: draft.focus,
            limit: base.limit, fonts: base.fonts, pack: draft.pack, examples: draft.pack)
    }
}
