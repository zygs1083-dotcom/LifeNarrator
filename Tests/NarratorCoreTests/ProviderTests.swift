import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NarratorCore

private let connectionSchema = #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}"#

@Test func providerCatalogIsValid() throws {
    let providers = ProviderCatalog.providers
    #expect(providers.count == 21)
    #expect(Set(providers.map(\.id)).count == providers.count)
    #expect(Set(providers.map(\.group)) == Set(ProviderPreset.Group.allCases))
    for provider in providers {
        #expect(!provider.name.zh.isEmpty && !provider.name.en.isEmpty)
        #expect(["http", "https"].contains(provider.baseURL.scheme))
        #expect(provider.baseURL.host != nil)
        #expect(!provider.path.isEmpty && !provider.path.hasPrefix("/"))
        if let url = provider.keyURL { #expect(url.scheme == "https" && url.host != nil) }
        if provider.keyRequired { #expect(provider.keyURL != nil) }
        let selection = ProviderConfiguration(presetID: provider.id, model: "fixture")
        #expect(try selection.validatedURL() == provider.baseURL)
        #expect(selection.isCloud == (provider.group != .local))
        #expect(try selection.generator(key: "") is AnthropicClient == (provider.api == .anthropic))
    }
}

@Test func openAIRequestModes() throws {
    for mode in StructuredOutput.allCases {
        let client = OpenAIChatClient(baseURL: URL(string: "https://example.test/api/v3/")!, path: "chat/completions", model: "fixture", key: "secret", structured: mode)
        let request = try client.makeRequest(system: "system", prompt: "user", schema: connectionSchema, maxTokens: 32)
        #expect(request.url!.absoluteString == "https://example.test/api/v3/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "fixture")
        #expect(body["max_tokens"] as? Int == 32)
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as! [[String: String]]
        #expect(messages[1] == ["role": "user", "content": "user"])
        let format = body["response_format"] as? [String: Any]
        switch mode {
        case .jsonSchema:
            #expect(messages[0] == ["role": "system", "content": "system"])
            #expect(format?["type"] as? String == "json_schema")
            let schema = format?["json_schema"] as! [String: Any]
            #expect(schema["strict"] == nil)
            #expect(schema["name"] as? String == "lifenarrator")
            #expect(NSDictionary(dictionary: schema["schema"] as! [String: Any]) == NSDictionary(dictionary: try JSONSerialization.jsonObject(with: Data(connectionSchema.utf8)) as! [String: Any]))
        case .jsonObject, .prompt:
            #expect(messages[0]["content"] == "system\n\(connectionSchema)\n只输出符合这个 schema 的 JSON")
            if mode == .jsonObject { #expect(format?["type"] as? String == "json_object") }
            else { #expect(format == nil) }
        }
    }
    let request = try OpenAIChatClient(baseURL: URL(string: "http://localhost:8080")!, path: "chat/completions", model: "local", structured: .prompt, stream: false)
        .makeRequest(system: nil, prompt: "user", schema: connectionSchema)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["max_tokens"] == nil)
    #expect(body["stream"] as? Bool == false)
    #expect((body["messages"] as! [[String: String]])[0]["content"] == "\(connectionSchema)\n只输出符合这个 schema 的 JSON")
}

@Test func deepSeekRequestsTurnThinkingOff() throws {
    for (preset, thinking) in [("deepseek", ["type": "disabled"]), ("openai", nil)] {
        let client = try ProviderConfiguration(presetID: preset, model: "fixture").generator(key: "secret") as! OpenAIChatClient
        let request = try client.makeRequest(system: nil, prompt: "user", schema: connectionSchema)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["thinking"] as? [String: String] == thinking)
    }
}

@Test func sseHandlesSplitLinesUTF8CommentsAndDone() {
    let bytes = Data(": keepalive\r\nevent: message\r\ndata: 一\r\ndata: 二\r\n\r\ndata: [DONE]\n\ndata: ignored\n\n".utf8)
    for split in 0...bytes.count {
        var parser = SSEParser()
        let events = parser.feed(Data(bytes.prefix(split))) + parser.feed(Data(bytes.dropFirst(split))) + parser.finish()
        #expect(events == ["一\n二"])
        #expect(parser.done)
    }
    var parser = SSEParser()
    #expect(parser.feed(Data("data: final".utf8)).isEmpty)
    #expect(parser.finish() == ["final"])
}

@Test func anthropicRequestUsesForcedTool() throws {
    let request = try AnthropicClient(baseURL: URL(string: "https://example.test/v1")!, model: "claude", key: "secret")
        .makeRequest(system: "system", prompt: "user", schema: connectionSchema)
    #expect(request.url!.absoluteString == "https://example.test/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["max_tokens"] as? Int == 1024)
    #expect(body["stream"] as? Bool == true)
    #expect(body["system"] as? String == "system")
    #expect(body["messages"] as? [[String: String]] == [["role": "user", "content": "user"]])
    #expect(body["tool_choice"] as? [String: String] == ["type": "tool", "name": "emit"])
    let tool = (body["tools"] as! [[String: Any]])[0]
    #expect(tool["name"] as? String == "emit")
    #expect(NSDictionary(dictionary: tool["input_schema"] as! [String: Any]) == NSDictionary(dictionary: try JSONSerialization.jsonObject(with: Data(connectionSchema.utf8)) as! [String: Any]))
    let noSystem = try AnthropicClient(baseURL: URL(string: "https://example.test")!, path: "api/messages", model: "claude", stream: false)
        .makeRequest(system: nil, prompt: "user", schema: connectionSchema, maxTokens: 42)
    let other = try JSONSerialization.jsonObject(with: noSystem.httpBody!) as! [String: Any]
    #expect(other["max_tokens"] as? Int == 42)
    #expect(other["system"] == nil)
    #expect(other["stream"] as? Bool == false)
}

@Test func legacyProviderSettingsMigrateAndRoundTrip() throws {
    struct Settings: Codable { var provider: ModelProvider; var generationAPI: ProviderConfiguration }
    let old = #"{"provider":"openAICompatible","generationAPI":{"baseURL":"https://legacy.test/prefix/","model":"old-model"}}"#
    let migrated = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
    #expect(migrated.provider == .api)
    #expect(migrated.generationAPI.presetID == "custom-openai")
    #expect(migrated.generationAPI.account == "provider.custom-openai")
    #expect(migrated.generationAPI.model == "old-model")
    let client = try migrated.generationAPI.generator(key: "") as! OpenAIChatClient
    #expect(try client.makeRequest(system: nil, prompt: "", schema: connectionSchema).url!.absoluteString == "https://legacy.test/prefix/v1/chat/completions")
    let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(migrated))
    #expect(roundTrip.provider == .api)
    #expect(roundTrip.generationAPI.baseURL == migrated.generationAPI.baseURL)
    var custom = ProviderConfiguration(presetID: "zhipu", model: "fixture", baseURL: "http://localhost:9999/v4", structured: .prompt)
    let restored = try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(custom))
    let override = try restored.generator(key: "") as! OpenAIChatClient
    #expect(override.structured == .prompt)
    #expect(try restored.validatedURL().absoluteString == "http://localhost:9999/v4")
    custom.baseURL = "not a URL"
    #expect(throws: ProviderConfigurationError.self) { try custom.validatedURL() }
    #expect(throws: ProviderConfigurationError.self) { try ProviderConfiguration().generator(key: "") }
    #expect(throws: ProviderConfigurationError.self) { try ProviderCatalog.provider("unknown") }
}
