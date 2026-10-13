import NarratorCore

/// Hand-written GBNF for the schemas `TextGenerator.generateJSON` receives.
public enum LlamaGrammar {
    public enum Failure: Error { case unsupportedSchema }

    public static func grammar(for schema: String) throws -> String {
        switch schema {
        case GenerationPrompts.compiledRuleSchema: return compiledRule
        case GenerationPrompts.quipsSchema: return quips
        case GenerationPrompts.spriteMarksSchema: return spriteMarks
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
    mark ::= "{" ws "\"i\"" ws ":" ws [0-7] ws "," ws "\"text\"" ws ":" ws text ws "," ws "\"emoji\"" ws ":" ws "[" ws emoji ws "]" ws "}"
    text ::= "\"" (zh | en) "\""
    zh ::= [一-鿿，。！？、：；～—…《》“”「」A-Za-z0-9 ]{1,14}
    en ::= [A-Za-z0-9 ,.!?'’:;…()-]{1,40}
    emoji ::= "\"" ebase [️]? ([‍] ebase [️]?){0,3} "\""
    ebase ::= [\U0001f300-\U0001faff☀-➿] [\U0001f3fb-\U0001f3ff]?
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
