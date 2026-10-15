import Foundation

/// sprite-examples.json is an array of scenes: id, zh/en {lines, marks}.
/// Each mark has a zero-based l, verbatim q, and voices keyed by PersonaCatalog examples IDs with {t, e}.
/// Additional personas can add a voice without duplicating screens or quotes.
public struct SpriteExample: Decodable, Sendable {
    public struct Screen: Decodable, Sendable {
        public struct Mark: Decodable, Sendable {
            public struct Voice: Decodable, Sendable {
                public let t: String
                public let e: String
            }
            public let l: Int
            public let q: String
            public let voices: [String: Voice]
        }
        public let lines: [String]
        public let marks: [Mark]
    }
    public let id: String
    public let zh: Screen
    public let en: Screen

    public static let pool: [SpriteExample] = {
        let url = Bundle.module.url(forResource: "sprite-examples", withExtension: "json")!
        return try! JSONDecoder().decode([SpriteExample].self, from: Data(contentsOf: url))
    }()

    func prompt(lang: Lang, persona: Persona, catalog: PersonaCatalog = .builtin) -> String {
        let screen = lang == .zh ? zh : en
        let lines = screen.lines.enumerated().map { "\($0.offset)| \($0.element)" }.joined(separator: "\n")
        let marks = screen.marks.map { mark in
            let voice = mark.voices[catalog[persona].examples.rawValue]!
            return RawMark(l: mark.l, q: mark.q, t: voice.t, e: voice.e)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try! encoder.encode(["marks": marks])
        return (lang == .zh ? "屏幕：\n" : "Screen:\n") + lines
            + (lang == .zh ? "\n输出：\n" : "\nOutput:\n") + String(decoding: json, as: UTF8.self)
    }
}
