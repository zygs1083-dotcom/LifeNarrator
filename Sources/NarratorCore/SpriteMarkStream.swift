import Foundation

public struct RawMark: Codable, Sendable, Equatable {
    public var l: Int
    public var q: String
    public var t: String
    public var e: String
}

public struct SpriteMarkStream: Sendable {
    private var scanned = 0
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var object = ""

    public init() {}

    public mutating func feed(_ partial: String) throws -> [RawMark] {
        var marks: [RawMark] = []
        // Scan scalars: a later UTF-8 chunk may extend the last grapheme cluster.
        for scalar in partial.unicodeScalars.dropFirst(scanned) {
            scanned += 1
            if depth >= 2 { object.unicodeScalars.append(scalar) }
            if inString {
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"": inString = true
            case "{":
                depth += 1
                if depth == 2 { object = "{" }
            case "}":
                if depth == 2 { marks.append(try JSONDecoder().decode(RawMark.self, from: Data(object.utf8))) }
                depth -= 1
            default: break
            }
        }
        return marks
    }
}
