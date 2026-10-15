import Foundation
import Testing
@testable import NarratorCore

@Test func personaCatalogLoadsSevenBilingualProfilesAndPackVoices() throws {
    let catalog = PersonaCatalog.builtin
    #expect(catalog.profiles.map(\.id) == [.sharp, .gentle, .chuuni, .teacher, .mom, .hype, .cat])
    for profile in catalog.profiles {
        for lang in Lang.allCases {
            #expect(!profile.name[lang].isEmpty)
            #expect(!profile.caption[lang].isEmpty)
            #expect(!profile.description[lang].isEmpty)
            #expect(!profile.fonts[lang].isEmpty)
        }
        #expect(profile.pack == profile.id)
        #expect(profile.examples == profile.id)
    }
    #expect(catalog[.sharp].fonts.zh == ["Hannotate SC", "Hanzipen SC", "Yuanti SC", "PingFang SC"])
    #expect(catalog[.gentle].description.en == "Gentle: soft, comforting, quietly encouraging, like a kind little creature. Can be a bit clingy, never preachy.")
}

@Test func personaDecodesLegacySettingsAndQuipStrings() throws {
    struct Settings: Codable { var persona: Persona }
    let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"persona":"sharp"}"#.utf8))
    #expect(settings.persona == .sharp)
    #expect(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self) == #"{"persona":"sharp"}"#)
    let custom = Persona(rawValue: "custom.example")
    #expect(try JSONDecoder().decode(Persona.self, from: JSONEncoder().encode(custom)) == custom)
    #expect(try !RuleLoader.loadBuiltin().rules.isEmpty)
    #expect(try !SpriteQuips.loadBuiltin().categories.isEmpty)
}

@Test func teacherPromptsIncludeFocusAndLimitsWithoutRequestDependentSystemPrefix() {
    let screen = SpriteScreen(lines: [(0, "HTTP 是什么")], tokens: 10)
    for lang in Lang.allCases {
        let first = GenerationPrompts.spriteMarks(app: "A", title: "First", screen: screen, exclude: [], persona: .teacher, lang: lang, k: 3)
        let next = GenerationPrompts.spriteMarks(app: "B", title: "Next", screen: .init(lines: [], tokens: 0),
            exclude: ["HTTP"], persona: .teacher, lang: lang, k: 8)
        #expect(first.system == next.system)
        #expect(first.system.contains(PersonaCatalog.builtin[.teacher].focus![lang]))
        #expect(first.system.contains(lang == .zh ? "不超过 22 个汉字" : "under 12 words"))
        let lines = first.system.components(separatedBy: "\n")
        let heading = lines.firstIndex(of: lang == .zh ? "怎么挑：" : "How to pick:")!
        #expect(lines[heading + 2] == "- " + PersonaCatalog.builtin[.teacher].focus![lang])
        let quips = GenerationPrompts.quips(rule: rule(), persona: .teacher, lang: lang)
        #expect(quips.contains(lang == .zh ? "不超过 22 个汉字" : "Under 12 words"))
    }
    #expect(SpriteGenerator.spriteLimit(persona: .teacher).zh == 26)
    #expect(SpriteGenerator.spriteLimit(persona: .teacher).en == 72)
    #expect(SpriteGenerator.spriteLimit(persona: .sharp).zh == 18)
    #expect(SpriteGenerator.spriteLimit(persona: .sharp).en == 48)
}

private struct PersonaStub: TextGenerator {
    let focus: Bool
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #expect(schema == PersonaGenerator.schema)
        #expect(system!.contains("persona"))
        #expect(prompt == "说话像东北大哥的程序员")
        var value: [String: Any] = ["name": ["zh": "东北大哥", "en": "Big Brother"], "emoji": "🧑‍💻",
            "description": ["zh": "热心爽快的程序员", "en": "A warm, straightforward programmer"], "pack": "gentle"]
        if focus { value["focus"] = ["zh": "优先解释代码", "en": "Explain code first"] }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

@Test func customPersonaGenerationPersistenceAndRemoval() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("personas.json")
    #expect(try PersonaCatalog.load(from: url).profiles.count == 7)
    let profile = try await PersonaGenerator.generate(input: "说话像东北大哥的程序员", generator: PersonaStub(focus: true))
    #expect(profile.id.rawValue.hasPrefix("custom."))
    #expect(UUID(uuidString: String(profile.id.rawValue.dropFirst(7))) != nil)
    #expect(profile.pack == .gentle && profile.examples == .gentle)
    let catalog = PersonaCatalog(custom: [profile])
    try catalog.save(to: url)
    let restored = try PersonaCatalog.load(from: url)
    #expect(restored.custom == [profile])
    #expect(GenerationPrompts.personaDescription(profile.id, lang: .zh, catalog: restored) == "热心爽快的程序员")
    let prompt = GenerationPrompts.spriteMarks(app: "X", title: "", screen: .init(lines: [], tokens: 0),
        exclude: [], persona: profile.id, lang: .zh, k: 4, catalog: restored)
    #expect(prompt.system.contains("优先解释代码"))
    #expect(prompt.system.contains("不超过 14 个汉字"))
    let withoutFocus = try await PersonaGenerator.generate(input: "说话像东北大哥的程序员", generator: PersonaStub(focus: false))
    #expect(withoutFocus.focus == nil)
    #expect(withoutFocus.id != profile.id)
    try PersonaCatalog(custom: []).save(to: url)
    #expect(try PersonaCatalog.load(from: url).custom.isEmpty)
    try Data("invalid".utf8).write(to: url)
    #expect(throws: (any Error).self) { try PersonaCatalog.load(from: url) }
}

@Test func pickerUsesOfflinePackButKeepsGeneratedPersonaAndSelectedIdentity() async throws {
    let profile = try await PersonaGenerator.generate(input: "说话像东北大哥的程序员", generator: PersonaStub(focus: false))
    let catalog = PersonaCatalog(custom: [profile])
    for persona in [Persona.teacher, .mom, .hype, .cat, profile.id] {
        let fallback = catalog[persona].pack
        var builtin = rule(quips: [quip("离线包台词", persona: fallback)])
        builtin.source = .builtin
        var picker = QuipPicker()
        var random = SeededRandom(seed: 9)
        let chosen = picker.pick(for: builtin, lang: .zh, persona: persona, pack: pack(), now: epoch, using: &random, catalog: catalog)
        #expect(chosen?.text == "离线包台词")
        #expect(chosen?.persona == persona)
        picker = QuipPicker()
        #expect(picker.pick(for: builtin, lang: .zh, persona: persona, pack: pack(), now: epoch,
            isRepeat: { $0 == "离线包台词" }, using: &random, catalog: catalog) == nil)
        let generated = rule(quips: [quip("真正的人设", persona: persona), quip("不要借这个", persona: fallback == persona ? .sharp : fallback)])
        picker = QuipPicker()
        #expect(picker.pick(for: generated, lang: .zh, persona: persona, pack: pack(), now: epoch, using: &random, catalog: catalog)?.text == "真正的人设")
        picker = QuipPicker()
        #expect(picker.pick(for: rule(), lang: .zh, persona: persona,
            pack: pack(generic: [quip("通用回退", persona: fallback)]), now: epoch, using: &random, catalog: catalog)?.text == "通用回退")
    }
}

private struct LongSpriteStub: TextGenerator {
    let lang: Lang
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #expect(schema == GenerationPrompts.spriteMarksLongSchema)
        return "{\"marks\":[{\"l\":0,\"q\":\"first phrase\",\"t\":\"" + String(repeating: lang == .zh ? "字" : "x", count: lang == .zh ? 26 : 72)
            + "\",\"e\":\"🌷\"},{\"l\":1,\"q\":\"second phrase\",\"t\":\"" + String(repeating: lang == .zh ? "字" : "x", count: lang == .zh ? 27 : 73) + "\",\"e\":\"🌷\"}]}"
    }
}

@Test func teacherSpriteAcceptsLongRemarksAndDropsOverLimit() async throws {
    let snapshot = semanticsSnapshot(["first phrase", "second phrase"])
    for lang in Lang.allCases {
        let marks = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
            app: "A", title: "T", exclude: [], persona: .teacher, lang: lang, k: 4, generator: LongSpriteStub(lang: lang), isRepeat: { _ in false }, onMark: { _ in })
        #expect(marks.count == 1)
        #expect(marks.first?.quip.text.count == (lang == .zh ? 26 : 72))
        #expect(marks.first?.quip.persona == .teacher)
    }
}

private struct PersonaQuipsStub: TextGenerator {
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #expect(prompt.contains("热心爽快的程序员"))
        #expect(schema == GenerationPrompts.quipsSchema)
        return #"{"quips":[{"text":"第一句","emoji":["🌷"]},{"text":"第二句","emoji":["🌷"]},{"text":"第三句","emoji":["🌷"]}]}"#
    }
}

@Test func generatedRuleQuipsKeepCustomPersonaID() async throws {
    let profile = try await PersonaGenerator.generate(input: "说话像东北大哥的程序员", generator: PersonaStub(focus: false))
    let quips = try await RuleCompiler.generateQuips(for: rule(), lang: .zh, persona: profile.id,
        generator: PersonaQuipsStub(), catalog: PersonaCatalog(custom: [profile]))
    #expect(quips.count == 3)
    #expect(quips.allSatisfy { $0.persona == profile.id })
}

private struct InvalidPersonaStub: TextGenerator {
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #"{"name":{"zh":"名字","en":"Name"},"emoji":"🌷","description":{"zh":"描述","en":"Description"},"pack":"teacher"}"#
    }
}

@Test func invalidGeneratedPersonaIsReported() async {
    await #expect(throws: PersonaGenerationError.self) {
        try await PersonaGenerator.generate(input: "Invalid pack", generator: InvalidPersonaStub())
    }
}
