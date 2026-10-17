import Foundation
import Testing
@testable import NarratorCore

// API providers receive these schemas as JSON; a typo only shows up as a failed request.
@Test func everySchemaIsValidJSON() throws {
    let schemas = [GenerationPrompts.spriteMarksSchema, GenerationPrompts.spriteMarksLongSchema,
                   GenerationPrompts.quipsSchema, GenerationPrompts.quipsLongSchema,
                   GenerationPrompts.compiledRuleSchema, SpriteAmbient.schema, SpriteAmbient.longSchema,
                   PersonaGenerator.schema]
    for schema in schemas {
        #expect(try JSONSerialization.jsonObject(with: Data(schema.utf8)) is [String: Any])
    }
}

// The model should describe the object before choosing its kind; keep the hand-written
// schema and both languages' examples aligned with that generation order.
@Test func compiledRuleSchemaAndExamplesShareGenerationOrder() throws {
    let order = ["label", "note", "kind", "sentiment", "aliases", "domains", "appNames", "highlight", "variables"]
    let schema = try #require(JSONSerialization.jsonObject(with: Data(GenerationPrompts.compiledRuleSchema.utf8)) as? [String: Any])
    #expect(schema["required"] as? [String] == order)
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    #expect(properties["note"]?["maxLength"] as? Int == 240)
    let keys = try NSRegularExpression(pattern: #""(\#(order.joined(separator: "|")))"\s*:"#)
    func orderedKeys(in text: String) -> [String] {
        keys.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }
    #expect(orderedKeys(in: GenerationPrompts.compiledRuleSchema) == order)
    for prompt in [GenerationPrompts.compileZH, GenerationPrompts.compileEN] {
        let examples = prompt.split(separator: "\n").filter { $0.hasPrefix("{") }
        #expect(examples.count == 4)
        var kinds: Set<String> = []
        for example in examples {
            #expect(orderedKeys(in: String(example)) == order)
            let compiled = try JSONDecoder().decode(CompiledRule.self, from: Data(example.utf8))
            kinds.insert(compiled.kind.rawValue)
        }
        #expect(kinds == ["site", "app", "person", "topic"])
    }
}

// The long variants are made by string replacement, which silently does nothing if the base text changes.
@Test func longSchemasDifferFromTheirBase() {
    #expect(GenerationPrompts.spriteMarksLongSchema != GenerationPrompts.spriteMarksSchema)
    #expect(GenerationPrompts.quipsLongSchema != GenerationPrompts.quipsSchema)
    #expect(SpriteAmbient.longSchema != SpriteAmbient.schema)
}
