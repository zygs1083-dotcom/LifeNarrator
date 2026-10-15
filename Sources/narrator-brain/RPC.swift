import Foundation
import NarratorCore

public enum BrainRPC {
    // Dates use ISO 8601; geometry uses Foundation CGRect's [[x,y],[width,height]].
    // lineIndex is zero based, null for title/app/site/time matches. Each snapshot is a change event.
    public static func handle(_ data: Data) throws -> Data? {
        func rpcError(_ code: Int, _ message: String, id: Any = NSNull()) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                "error": ["code": code, "message": message]], options: [.sortedKeys])
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return try rpcError(-32700, "Parse error") }
        guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String,
              request["id"] == nil || request["id"] is String || request["id"] is NSNull
                || (request["id"] is NSNumber && String(cString: (request["id"] as! NSNumber).objCType) != "c"),
              request["params"] == nil || request["params"] is [String: Any] || request["params"] is [Any]
        else { return try rpcError(-32600, "Invalid Request") }
        let id = request["id"] ?? NSNull()
        let result: Any
        switch method {
        case "ping": result = ["version": NarratorCore.version]
        case "matchRules":
            struct Parameters: Decodable { var snapshot: ContextSnapshot; var rules: [Rule] }
            let params: Parameters
            do {
                let encoded = try JSONSerialization.data(withJSONObject: request["params"] ?? [:])
                params = try RuleLoader.decoder().decode(Parameters.self, from: encoded)
                try params.rules.forEach(RuleLoader.validate)
            } catch {
                return request["id"] == nil ? nil : try rpcError(-32602, "Invalid params: \(error)", id: id)
            }
            result = RuleMatcher(rules: params.rules).candidates(in: params.snapshot,
                now: params.snapshot.capturedAt, appChanged: true, hostChanged: true).map {
                    ["ruleId": $0.rule.id, "lineIndex": $0.lineIndex.map { $0 as Any } ?? NSNull()]
                }
        default: return request["id"] == nil ? nil : try rpcError(-32601, "Method not found", id: id)
        }
        return request["id"] == nil ? nil : try JSONSerialization.data(withJSONObject:
            ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])
    }
}
