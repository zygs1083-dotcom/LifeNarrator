import Foundation
import Testing
import NarratorCore
@testable import NarratorBrain

private func response(_ json: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: #require(try BrainRPC.handle(Data(json.utf8)))) as! [String: Any]
}

@Test func pingAndProtocolErrors() throws {
    let ping = try response(#"{"jsonrpc":"2.0","id":"中文","method":"ping"}"#)
    #expect(ping["id"] as? String == "中文")
    #expect((ping["result"] as? [String: String])?["version"] == NarratorCore.version)
    for (input, code) in [("{", -32700), ("[]", -32600),
        (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":2,"method":"unknown"}"#, -32601),
        (#"{"jsonrpc":"2.0","id":3,"method":"matchRules","params":{}}"#, -32602)] {
        #expect((try response(input)["error"] as? [String: Any])?["code"] as? Int == code)
    }
    #expect(try BrainRPC.handle(Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8)) == nil)
    #expect(try BrainRPC.handle(Data(#"{"jsonrpc":"2.0","method":"unknown"}"#.utf8)) == nil)
}

@Test func matchingUsesCoreAndRejectsInvalidRules() throws {
    let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let snapshot = ContextSnapshot(bundleId: "fixture", appName: "Fixture", pid: 1,
        windowFrame: frame, contentFrame: frame,
        textLines: [TextLine(text: "无关文字", rect: frame), TextLine(text: "又要上班了", rect: frame)],
        capturedAt: Date(timeIntervalSince1970: 0))
    var rule = Rule(id: "work", kind: .topic, source: .user, label: Label(zh: "上班", en: "Work"),
        sentiment: .dislike, match: Match(aliases: ["上班"]), highlight: true)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    func call() throws -> [String: Any] {
        let params: [String: Any] = ["snapshot": try JSONSerialization.jsonObject(with: encoder.encode(snapshot)),
            "rules": try JSONSerialization.jsonObject(with: encoder.encode([rule]))]
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": "matchRules", "params": params])
        return try JSONSerialization.jsonObject(with: #require(try BrainRPC.handle(data))) as! [String: Any]
    }
    let candidates = try call()["result"] as! [[String: Any]]
    #expect(candidates.count == 1)
    #expect(candidates[0]["ruleId"] as? String == "work")
    #expect(candidates[0]["lineIndex"] as? Int == 1)
    rule.kind = .time
    #expect((try call()["error"] as? [String: Any])?["code"] as? Int == -32602)
}
