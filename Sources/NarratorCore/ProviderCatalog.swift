import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum StructuredOutput: String, Codable, CaseIterable, Sendable {
    case jsonSchema = "json_schema", jsonObject = "json_object", prompt
}

public struct ProviderPreset: Codable, Identifiable, Sendable {
    public enum Group: String, Codable, CaseIterable, Sendable { case cn, global, local, custom }
    public enum API: String, Codable, Sendable { case openai, anthropic }
    public struct Name: Codable, Sendable { public let zh: String; public let en: String }
    public let id: String
    public let name: Name
    public let group: Group
    public let api: API
    public let baseURL: URL
    public let path: String
    public let structured: StructuredOutput
    public let stream: Bool
    public let keyRequired: Bool
    public let keyURL: URL?
    public let modelsEndpoint: Bool
    public let suggestedModels: [String]
}

public enum ProviderCatalog {
    public static let providers: [ProviderPreset] = {
        let url = Bundle.module.url(forResource: "providers", withExtension: "json")!
        return try! JSONDecoder().decode([ProviderPreset].self, from: Data(contentsOf: url))
    }()

    public static func provider(_ id: String) throws -> ProviderPreset {
        guard let preset = providers.first(where: { $0.id == id }) else { throw ProviderConfigurationError.unknownProvider(id) }
        return preset
    }
}

public enum ModelProvider: String, Codable, CaseIterable, Sendable {
    case builtin, api, none

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "openAICompatible" { self = .api }
        else if let value = Self(rawValue: raw) { self = value }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown provider: \(raw)") }
    }
}

public enum ProviderConfigurationError: Error { case unknownProvider(String), invalidURL, missingModel, invalidResponse }

public struct ProviderConfiguration: Codable, Sendable {
    public var presetID: String
    public var model: String
    public var baseURL: String?
    public var structured: StructuredOutput?
    public init(presetID: String = "openai", model: String = "", baseURL: String? = nil, structured: StructuredOutput? = nil) {
        self.presetID = presetID; self.model = model; self.baseURL = baseURL; self.structured = structured
    }

    private enum CodingKeys: String, CodingKey { case presetID, model, baseURL, structured }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        structured = try c.decodeIfPresent(StructuredOutput.self, forKey: .structured)
        if let presetID = try c.decodeIfPresent(String.self, forKey: .presetID) {
            self.presetID = presetID
            _ = try ProviderCatalog.provider(presetID)
            baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        } else {
            presetID = "custom-openai"
            structured = .jsonSchema
            let legacy = try c.decode(String.self, forKey: .baseURL)
            baseURL = legacy.isEmpty ? "" : legacy.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
        }
    }

    public var account: String { "provider.\(presetID)" }
    public func validatedURL() throws -> URL {
        let preset = try ProviderCatalog.provider(presetID)
        guard let url = URL(string: baseURL ?? preset.baseURL.absoluteString), ["http", "https"].contains(url.scheme), url.host != nil else {
            throw ProviderConfigurationError.invalidURL
        }
        return url
    }
    public var isCloud: Bool { (try? ProviderCatalog.provider(presetID).group) != .local }

    public func generator(key: String) throws -> any TextGenerator {
        let preset = try ProviderCatalog.provider(presetID)
        let url = try validatedURL()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderConfigurationError.missingModel }
        switch preset.api {
        case .openai:
            return OpenAIChatClient(baseURL: url, path: preset.path, model: model, key: key,
                                    structured: structured ?? preset.structured, stream: preset.stream)
        case .anthropic:
            return AnthropicClient(baseURL: url, path: preset.path, model: model, key: key, stream: preset.stream)
        }
    }

    public func fetchModels(key: String, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: try validatedURL().appendingPathComponent("models"))
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard (200..<300).contains(status) else { throw HTTPClientError.status(status, String(decoding: data, as: UTF8.self)) }
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return try JSONDecoder().decode(Response.self, from: data).data.map(\.id).sorted()
    }
}
