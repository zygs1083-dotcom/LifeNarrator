extension GenerationPrompts {
    public static let chatSchema = #"""
    {"type":"object","required":["intent","reply","rule","setting","memories","forget"],"additionalProperties":false,"properties":{
      "intent":{"enum":["chat","rule","setting","remember","forget","recall"]},
      "reply":{"type":"string","minLength":1,"maxLength":300},
      "rule":{"type":["string","null"]},
      "setting":{"anyOf":[{"type":"null"},{"type":"object","required":["liveliness","paused","persona"],"additionalProperties":false,"properties":{
        "liveliness":{"enum":["quiet","lively","rowdy",null]},"paused":{"type":["boolean","null"]},"persona":{"type":["string","null"]}}}]},
      "memories":{"type":"array","items":{"type":"object","required":["kind","text"],"additionalProperties":false,"properties":{
        "kind":{"enum":["fact","preference","nickname"]},"text":{"type":"string","minLength":1,"maxLength":40}}}},
      "forget":{"type":["string","null"]}
    }}
    """#
}
