import Foundation
import NarratorCore

struct RPCGeneratorConfiguration: Decodable {
    enum Kind: String, Decodable { case none, api, builtin }
    let kind: Kind
    let presetId: String?
    let model: String?
    let baseURL: String?
    let structured: StructuredOutput?
    let key: String?

    func makeGenerator() throws -> (any TextGenerator)? {
        switch kind {
        case .none: return nil
        case .builtin: throw BrainRPCError(code: -32001, message: "builtin generator is not supported")
        case .api:
            guard let presetId, let model, let key else {
                throw BrainRPCError(code: -32602, message: "api requires presetId, model and key")
            }
            return try ProviderConfiguration(presetID: presetId, model: model, baseURL: baseURL,
                                             structured: structured).generator(key: key)
        }
    }
}

struct RPCConfiguration: Decodable {
    struct Settings: Decodable {
        struct SystemOne: Decodable { let baseURL: String; let model: String; let key: String }
        let liveliness: Liveliness
        let markGap: TimeInterval
        let paused: Bool
        let blacklist: [String]
        let persona: Persona
        let lang: Lang
        let disabledBuiltinIds: Set<String>
        let maxOnScreen: Int
        let systemOne: SystemOne?
        let ownProcessID: Int32
        let memoryEnabled: Bool

        func makeSettings(modelAvailable: Bool) throws -> BrainSettings {
            guard markGap >= 0, maxOnScreen > 0 else {
                throw BrainRPCError(code: -32602, message: "markGap must be nonnegative and maxOnScreen positive")
            }
            let connection = try systemOne.map { configuration -> BrainSettings.SystemOne in
                guard let url = URL(string: configuration.baseURL), ["http", "https"].contains(url.scheme), url.host != nil else {
                    throw ProviderConfigurationError.invalidURL
                }
                return .init(model: configuration.model, connection: .success((url, configuration.key)))
            }
            return BrainSettings(liveliness: liveliness, markGap: markGap, paused: paused, blacklist: blacklist,
                persona: persona, lang: lang, disabledBuiltinIds: disabledBuiltinIds, maxOnScreen: maxOnScreen,
                modelAvailable: modelAvailable, systemOne: connection, ownProcessID: ownProcessID,
                memoryEnabled: memoryEnabled)
        }
    }
    let settings: Settings
    let rules: [Rule]
    let customPersonas: [PersonaProfile]
    let generator: RPCGeneratorConfiguration
    let dataDirectory: String

    func makeContent() throws -> BrainContent {
        try rules.forEach(RuleLoader.validate)
        guard Set(customPersonas.map(\.id)).count == customPersonas.count,
              customPersonas.allSatisfy({ $0.id.rawValue.hasPrefix("custom.") && [.sharp, .gentle, .chuuni].contains($0.pack)
                  && [.sharp, .gentle, .chuuni].contains($0.examples) && $0.limit.zh == 14 && $0.limit.en == 8 }) else {
            throw PersonaGenerationError.invalidProfile
        }
        let catalog = PersonaCatalog(custom: customPersonas)
        guard catalog.profiles.contains(where: { $0.id == settings.persona }), !dataDirectory.isEmpty else {
            throw BrainRPCError(code: -32602, message: "Unknown persona or empty dataDirectory")
        }
        return BrainContent(rules: rules, builtin: try RuleLoader.loadBuiltin(), personas: catalog)
    }
}
