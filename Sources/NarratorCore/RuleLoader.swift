import Foundation

public struct RuleValidationError: Error, CustomStringConvertible, Sendable {
    public let ruleID: String
    public let reason: String
    public var description: String { "Rule \(ruleID): \(reason)" }
}

public struct QuipPack: Codable, Sendable {
    public var version: Int
    public var rules: [Rule]
    public var generic: [String: [Quip]]
    public init(version: Int, rules: [Rule], generic: [String: [Quip]]) {
        self.version = version; self.rules = rules; self.generic = generic
    }
}

public enum RuleLoader {
    public static func validate(_ rule: Rule) throws {
        let valid: Bool
        switch rule.kind {
        case .app: valid = !(rule.match.bundleIds ?? []).isEmpty || !(rule.match.appNames ?? []).isEmpty
        case .site: valid = !(rule.match.domains ?? []).isEmpty
        case .person: valid = !(rule.match.aliases ?? []).isEmpty && rule.match.region != nil
        case .topic: valid = !(rule.match.aliases ?? []).isEmpty
        case .time: valid = rule.match.when != nil && rule.match.when != .any
        }
        if !valid { throw RuleValidationError(ruleID: rule.id, reason: "missing required match fields for \(rule.kind.rawValue)") }
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func loadBuiltin() throws -> QuipPack {
        let url = Bundle.module.url(forResource: "quips", withExtension: "json")!
        let pack = try decoder().decode(QuipPack.self, from: Data(contentsOf: url))
        try pack.rules.forEach(validate)
        return pack
    }

    public static func load(from url: URL) throws -> [Rule] {
        let rules = try decoder().decode([Rule].self, from: Data(contentsOf: url))
        try rules.forEach(validate)
        return rules
    }

    public static func save(_ rules: [Rule], to url: URL) throws {
        try rules.forEach(validate)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: url, options: .atomic)
    }
}
