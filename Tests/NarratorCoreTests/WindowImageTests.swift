import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NarratorCore

private let imageSchema = #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#

@Test func imageProviderConfigurationDefaultsAndRoundTrips() throws {
    for json in [#"{"presetID":"openai","model":"fixture"}"#, #"{"baseURL":"http://localhost","model":"fixture"}"#] {
        let config = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(json.utf8))
        #expect(!config.vision)
    }
    let config = ProviderConfiguration(presetID: "anthropic", model: "fixture", vision: true)
    #expect(try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(config)).vision)
    #expect((try config.generator(key: "") as! AnthropicClient).jpeg == nil)
}

@Test func imageRequestShapesAndUnchangedTextBodies() throws {
    let jpeg = WindowImage.connectionTestJPEG
    let schema = try JSONSerialization.jsonObject(with: Data(imageSchema.utf8))
    let openai = OpenAIChatClient(baseURL: URL(string: "https://fixture.test")!, path: "chat/completions", model: "fixture")
    let anthropic = AnthropicClient(baseURL: URL(string: "https://fixture.test")!, model: "fixture")
    let legacyOpenAI: [String: Any] = ["model": "fixture", "messages": [["role": "system", "content": "system"], ["role": "user", "content": "user"]],
        "stream": true, "response_format": ["type": "json_schema", "json_schema": ["name": "lifenarrator", "schema": schema]]]
    let legacyAnthropic: [String: Any] = ["model": "fixture", "max_tokens": 1024, "stream": true,
        "messages": [["role": "user", "content": "user"]], "system": "system",
        "tools": [["name": "emit", "input_schema": schema]], "tool_choice": ["type": "tool", "name": "emit"]]
    for (body, legacy) in [
        (try openai.makeRequest(system: "system", prompt: "user", schema: imageSchema).httpBody!, legacyOpenAI),
        (try anthropic.makeRequest(system: "system", prompt: "user", schema: imageSchema).httpBody!, legacyAnthropic)
    ] {
        // JSON member order is unspecified; compare every payload byte after canonical ordering.
        #expect(try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: body), options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]))
    }
    let withOpenAI = openai.attachingJPEG(jpeg) as! OpenAIChatClient
    let request = try withOpenAI.makeRequest(system: "system", prompt: "user", schema: imageSchema)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let messages = body["messages"] as! [[String: Any]]
    #expect(messages[0]["content"] as? String == "system")
    let content = messages[1]["content"] as! [[String: Any]]
    #expect(content[0] as? [String: String] == ["type": "text", "text": "user"])
    #expect(content[1]["type"] as? String == "image_url")
    #expect((content[1]["image_url"] as! [String: String])["url"] == "data:image/jpeg;base64," + jpeg.base64EncodedString())
    let withAnthropic = anthropic.attachingJPEG(jpeg) as! AnthropicClient
    let aRequest = try withAnthropic.makeRequest(system: "system", prompt: "user", schema: imageSchema)
    let aBody = try JSONSerialization.jsonObject(with: aRequest.httpBody!) as! [String: Any]
    let aContent = (aBody["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
    #expect(aContent[0]["type"] as? String == "image")
    #expect(aContent[0]["source"] as? [String: String] == ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()])
    #expect(aContent[1] as? [String: String] == ["type": "text", "text": "user"])
    #expect(openai.jpeg == nil && anthropic.jpeg == nil)
    #expect(jpeg.starts(with: [0xff, 0xd8]) && jpeg.suffix(2) == Data([0xff, 0xd9]))
}

@Test func imageRedactionsCoverSensitiveFieldsAndPrivacyRanges() {
    let sensitive = CGRect(x: -100, y: 20, width: 80, height: 15)
    let field = TextLine(text: "draft", rect: CGRect(x: 10, y: 100, width: 300, height: 30), role: .field)
    let text = TextLine(text: "😺 邮箱 a@example.com 电话 13812345678 网址 https://test.com 数字 123456789012",
        rect: CGRect(x: 10, y: 200, width: 1200, height: 20))
    let snapshot = ContextSnapshot(bundleId: "fixture", appName: "Fixture", pid: 1,
        windowFrame: CGRect(x: -200, y: 0, width: 1600, height: 900), contentFrame: .zero,
        textLines: [field, text], sensitiveRects: [sensitive], capturedAt: Date())
    let rects = WindowImage.redactions(in: snapshot)
    #expect(rects[0] == sensitive.insetBy(dx: -60, dy: -60))
    #expect(rects[1] == field.rect)
    #expect(SpritePrompt.privacyRanges(in: text.text).count == 4)
    #expect(rects == [sensitive.insetBy(dx: -60, dy: -60), field.rect, text.rect])
    for privateText in ["email a@example.com", "phone 13812345678", "number 123456789012", "URL https://test.com"] {
        var singleLine = snapshot
        singleLine.sensitiveRects = []
        singleLine.textLines = [TextLine(text: privateText, rect: CGRect(x: 10, y: 200, width: 300, height: 120))]
        #expect(WindowImage.redactions(in: singleLine) == singleLine.textLines.map(\.rect))
    }
}

@Test func imageNarrationPromptOnlyAddsVisionInstruction() {
    for lang in Lang.allCases {
        let screen = SpriteScreen(lines: [(0, "fixture text")], tokens: 10)
        var first = SeededRandom(seed: 15), second = SeededRandom(seed: 15), third = SeededRandom(seed: 15)
        let base = GenerationPrompts.spriteMarks(app: "Fixture", title: "T", screen: screen, exclude: [], persona: .gentle, lang: lang, k: 3, using: &first)
        let off = GenerationPrompts.spriteMarks(app: "Fixture", title: "T", screen: screen, exclude: [], persona: .gentle, lang: lang, k: 3, using: &second, vision: false)
        let on = GenerationPrompts.spriteMarks(app: "Fixture", title: "T", screen: screen, exclude: [], persona: .gentle, lang: lang, k: 3, using: &third, vision: true)
        #expect(off.system == base.system && off.user == base.user)
        #expect(on.system == base.system + "\n\n" + WindowImagePrompt.narration(lang: lang))
        #expect(on.user == base.user)
    }
}

@Test func ocrFieldRowsExcludeDraftsWithoutSuppressingNearbyMessages() {
    let frame = CGRect(x: -200, y: 100, width: 1000, height: 800)
    let message = TextLine(text: "latest message", rect: CGRect(x: -100, y: 600, width: 300, height: 20))
    let draft = TextLine(text: "unsent draft", rect: CGRect(x: -100, y: 630, width: 300, height: 20), role: .field)
    let snapshot = ContextSnapshot(bundleId: "fixture", appName: "Fixture", pid: 1,
        windowFrame: frame, contentFrame: frame, textLines: [message, draft], textSource: .ocr, capturedAt: Date())
    #expect(snapshot.sensitiveRects.isEmpty)
    #expect(SpritePrompt.screen(in: snapshot).lines.map(\.lineIndex) == [0])
    #expect(SpritePrompt.screen(in: snapshot).text == "0| latest message")
    #expect(WindowImage.redactions(in: snapshot) == [draft.rect])
}
