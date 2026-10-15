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

// The long variants are made by string replacement, which silently does nothing if the base text changes.
@Test func longSchemasDifferFromTheirBase() {
    #expect(GenerationPrompts.spriteMarksLongSchema != GenerationPrompts.spriteMarksSchema)
    #expect(GenerationPrompts.quipsLongSchema != GenerationPrompts.quipsSchema)
    #expect(SpriteAmbient.longSchema != SpriteAmbient.schema)
}
