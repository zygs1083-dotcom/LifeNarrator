import Foundation
import NarratorCore
import NarratorBrain

/// Hand-written GBNF for the schemas `TextGenerator.generateJSON` receives.
public enum LlamaGrammar {
    public enum Failure: Error { case unsupportedSchema }

    public static func grammar(for schema: String) throws -> String {
        switch schema {
        case ChatEngine.schema: return chat
        case GenerationPrompts.compiledRuleSchema: return compiledRule
        case GenerationPrompts.quipsSchema: return quips
        case GenerationPrompts.quipsLongSchema: return quipsLong
        case SpriteAmbient.schema: return ambient
        case SpriteAmbient.longSchema: return ambientLong
        case PersonaGenerator.schema: return persona
        case GenerationPrompts.spriteMarksSchema: return spriteMarks
        case GenerationPrompts.spriteMarksLongSchema: return spriteMarksLong
        default: throw Failure.unsupportedSchema
        }
    }

    /// 3–12 quips. A text is Chinese (CJK, punctuation and a few ASCII characters, at most 14) or
    /// English (ASCII, at most 40); both branches stay open until a CJK character or the length decides.
    /// Each emoji string is one emoji, optionally a ZWJ sequence.
    public static let quips = #"""
    root ::= "{" ws "\"quips\"" ws ":" ws "[" ws quip (ws "," ws quip){2,11} ws "]" ws "}" ws
    quip ::= "{" ws "\"text\"" ws ":" ws text ws "," ws "\"emoji\"" ws ":" ws "[" ws emoji (ws "," ws emoji){0,2} ws "]" ws "}"
    text ::= "\"" (zh | en) "\""
    zh ::= [一-鿿，。！？、：；～—…《》“”「」A-Za-z0-9 ]{1,14}
    en ::= [A-Za-z0-9 ,.!?'’:;…()-]{1,40}
    emoji ::= "\"" ebase [️]? ([‍] ebase [️]?){0,3} "\""
    ebase ::= [\U0001f300-\U0001faff☀-➿] [\U0001f3fb-\U0001f3ff]?
    ws ::= [ \t\n\r]{0,4}
    """#

    public static let spriteMarks = #"""
    root ::= "{" ws "\"marks\"" ws ":" ws "[" ws (mark (ws "," ws mark){0,7})? ws "]" ws "}" ws
    mark ::= "{" ws "\"l\"" ws ":" ws line ws "," ws "\"q\"" ws ":" ws quote ws "," ws "\"t\"" ws ":" ws text ws "," ws "\"e\"" ws ":" ws emoji ws "}"
    line ::= [0-9] | [1-9] [0-9]
    quote ::= "\"" qchar{2,32} "\""
    qchar ::= [^"\\\x7f\x00-\x1f] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
    text ::= "\"" (zh | en) "\""
    zh ::= [一-鿿，。！？、：；～—…《》“”「」%.A-Za-z0-9 ]{1,20}
    en ::= [A-Za-z0-9 ,.!?'’:;…()%-]{1,56}
    emoji ::= "\"" ebase [️]? ([‍] ebase [️]?){0,3} "\""
    ebase ::= [\U0001f300-\U0001faff☀-➿] [\U0001f3fb-\U0001f3ff]?
    ws ::= [ \t\n\r]{0,4}
    """#

    public static let ambient = #"""
    root ::= "{" ws "\"lines\"" ws ":" ws "[" ws aside (ws "," ws aside){2,5} ws "]" ws "}" ws
    aside ::= "{" ws "\"t\"" ws ":" ws text ws "," ws "\"e\"" ws ":" ws emoji ws "}"
    """# + "\n" + spriteMarks.split(separator: "\n").filter {
        line in ["text ::=", "zh ::=", "en ::=", "emoji ::=", "ebase ::=", "ws ::="].contains { line.hasPrefix($0) }
    }.joined(separator: "\n")

    public static let spriteMarksLong = spriteMarks
        .replacingOccurrences(of: "{1,20}", with: "{1,28}")
        .replacingOccurrences(of: "{1,56}", with: "{1,80}")

    public static let ambientLong = ambient
        .replacingOccurrences(of: "{1,20}", with: "{1,28}")
        .replacingOccurrences(of: "{1,56}", with: "{1,80}")

    public static let quipsLong = quips
        .replacingOccurrences(of: "{1,14}", with: "{1,22}")
        .replacingOccurrences(of: "{1,40}", with: "{1,60}")

    public static let persona = #"""
    root ::= "{" ws "\"name\"" ws ":" ws label ws "," ws "\"emoji\"" ws ":" ws emoji ws "," ws "\"description\"" ws ":" ws label (ws "," ws "\"focus\"" ws ":" ws label)? ws "," ws "\"pack\"" ws ":" ws pack ws "}" ws
    label ::= "{" ws "\"zh\"" ws ":" ws string ws "," ws "\"en\"" ws ":" ws string ws "}"
    pack ::= "\"sharp\"" | "\"gentle\"" | "\"chuuni\""
    string ::= "\"" char{1,500} "\""
    char ::= [^"\\\x7f\x00-\x1f] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
    emoji ::= "\"" ebase [️]? ([‍] ebase [️]?){0,3} "\""
    ebase ::= [\U0001f300-\U0001faff☀-➿] [\U0001f3fb-\U0001f3ff]?
    ws ::= [ \t\n\r]{0,4}
    """#

    public static let chat = #"""
    root ::= "{" ws "\"intent\"" ws ":" ws intent ws "," ws "\"reply\"" ws ":" ws reply ws "," ws "\"rule\"" ws ":" ws nullable ws "," ws "\"setting\"" ws ":" ws setting ws "," ws "\"memories\"" ws ":" ws "[" ws (memory (ws "," ws memory)*)? ws "]" ws "," ws "\"forget\"" ws ":" ws nullable ws "}" ws
    intent ::= "\"chat\"" | "\"rule\"" | "\"setting\"" | "\"remember\"" | "\"forget\"" | "\"recall\""
    reply ::= "\"" char{1,300} "\""
    nullable ::= string | "null"
    setting ::= "null" | "{" ws "\"liveliness\"" ws ":" ws ("\"quiet\"" | "\"lively\"" | "\"rowdy\"" | "null") ws "," ws "\"paused\"" ws ":" ws ("true" | "false" | "null") ws "," ws "\"persona\"" ws ":" ws nullable ws "}"
    memory ::= "{" ws "\"kind\"" ws ":" ws ("\"fact\"" | "\"preference\"" | "\"nickname\"") ws "," ws "\"text\"" ws ":" ws "\"" char{1,40} "\"" ws "}"
    string ::= "\"" char* "\""
    char ::= [^"\\\x7f\x00-\x1f] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
    ws ::= [ \t\n\r]{0,4}
    """#

    public static let compiledRule = #"""
    root ::= "{" ws "\"kind\"" ws ":" ws kind ws "," ws "\"label\"" ws ":" ws label ws "," ws "\"sentiment\"" ws ":" ws sentiment ws "," ws "\"note\"" ws ":" ws string ws "," ws "\"aliases\"" ws ":" ws aliases ws "," ws "\"domains\"" ws ":" ws domains ws "," ws "\"appNames\"" ws ":" ws appNames ws "," ws "\"highlight\"" ws ":" ws ("true" | "false") ws "," ws "\"variables\"" ws ":" ws variables ws "}" ws
    kind ::= "\"app\"" | "\"site\"" | "\"person\"" | "\"topic\""
    sentiment ::= "\"dislike\"" | "\"like\"" | "\"neutral\""
    label ::= "{" ws "\"zh\"" ws ":" ws string ws "," ws "\"en\"" ws ":" ws string ws "}"
    aliases ::= "[" ws (string (ws "," ws string){0,7})? ws "]"
    domains ::= "[" ws (string (ws "," ws string){0,5})? ws "]"
    appNames ::= "[" ws (string (ws "," ws string){0,3})? ws "]"
    variables ::= "{" ws (string ws ":" ws string (ws "," ws string ws ":" ws string){0,3})? ws "}"
    string ::= "\"" char{0,80} "\""
    char ::= [^"\\\x7f\x00-\x1f] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
    ws ::= [ \t\n\r]{0,4}
    """#
}
