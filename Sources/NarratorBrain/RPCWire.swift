import Foundation

indirect enum RPCValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Decimal), string(String), array([RPCValue]), object([String: RPCValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([RPCValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: RPCValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var validID: Bool {
        switch self { case .null, .string, .number: true; default: false }
    }

    // Foundation's CGRect coding is an array; keep its process-local format out of the wire contract.
    private func geometry(toWire: Bool) -> RPCValue {
        switch self {
        case .array(let a):
            if toWire, a.count == 2, case .array(let origin) = a[0], case .array(let size) = a[1],
               origin.count == 2, size.count == 2,
               (origin + size).allSatisfy({ if case .number = $0 { true } else { false } }) {
                return .object(["x": origin[0], "y": origin[1], "w": size[0], "h": size[1]])
            }
            return .array(a.map { $0.geometry(toWire: toWire) })
        case .object(let o):
            if !toWire, Set(o.keys) == ["x", "y", "w", "h"] {
                return .array([.array([o["x"]!, o["y"]!]), .array([o["w"]!, o["h"]!])])
            }
            return .object(o.mapValues { $0.geometry(toWire: toWire) })
        default: return self
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> RPCValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value)).geometry(toWire: true)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(geometry(toWire: false)))
    }

    func line() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

public struct BrainRPCError: Error, Codable, Sendable {
    public let code: Int
    public let message: String
    let data: RPCValue?

    public init(code: Int, message: String) { self.code = code; self.message = message; data = nil }
}

struct RPCNull: Codable, Sendable {
    init() {}
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        guard c.decodeNil() else {
            throw DecodingError.typeMismatch(Self.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected null"))
        }
    }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encodeNil() }
}
