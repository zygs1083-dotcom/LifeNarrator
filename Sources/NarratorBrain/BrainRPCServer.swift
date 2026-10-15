import Foundation
import NarratorCore

@MainActor public final class BrainRPCServer {
    private enum Event: Sendable { case line(String), failure(any Error) }
    private let peer: RPCPeer
    private let events = AsyncStream<Event>.makeStream()
    private let generatorFactory: (RPCGeneratorConfiguration) throws -> (any TextGenerator)?
    private var connectionTests: [UUID: Task<Void, Never>] = [:]
    private var brain: SpriteBrain?
    private var directory: URL?

    public convenience init(writeLine: @escaping (String) throws -> Void) {
        self.init(writeLine: writeLine, generatorFactory: { try $0.makeGenerator() })
    }

    init(writeLine: @escaping (String) throws -> Void,
         generatorFactory: @escaping (RPCGeneratorConfiguration) throws -> (any TextGenerator)?) {
        peer = RPCPeer(writeLine: writeLine)
        self.generatorFactory = generatorFactory
        let continuation = events.continuation
        peer.onFailure = { continuation.yield(.failure($0)) }
    }

    public func run(lines: AsyncThrowingStream<String, any Error>) async throws {
        let continuation = events.continuation
        let reader = Task {
            do {
                for try await line in lines { continuation.yield(.line(line)) }
            } catch { continuation.yield(.failure(error)) }
            continuation.finish()
        }
        defer {
            reader.cancel()
            for task in connectionTests.values { task.cancel() }
            continuation.finish()
            brain?.windowChanged()
            peer.close()
        }
        for await event in events.stream {
            switch event {
            case .line(let line): try receive(line)
            case .failure(let error): throw error
            }
        }
    }

    func receive(_ line: String) throws {
        let value: RPCValue
        do { value = try JSONDecoder().decode(RPCValue.self, from: Data(line.utf8)) }
        catch { try reply(error: BrainRPCError(code: -32700, message: "Parse error"), id: .null); return }
        guard case .object(let object) = value, object["jsonrpc"] == .string("2.0") else {
            try reply(error: BrainRPCError(code: -32600, message: "Invalid Request"), id: .null); return
        }
        if object["method"] == nil, object["result"] != nil || object["error"] != nil {
            try peer.receive(object)
            return
        }
        guard case .string(let method) = object["method"], object["id"]?.validID ?? true,
              object["params"].map({ if case .object = $0 { true } else if case .array = $0 { true } else { false } }) ?? true else {
            try reply(error: BrainRPCError(code: -32600, message: "Invalid Request"), id: .null); return
        }
        let params = object["params"] ?? .object([:])
        let result: RPCValue
        do {
            if method == "testConnection" {
                struct Params: Decodable { let generator: RPCGeneratorConfiguration }
                let configuration = try params.decode(Params.self).generator
                guard configuration.kind == .api, let generator = try generatorFactory(configuration) else {
                    throw BrainRPCError(code: -32602, message: "testConnection requires an API generator")
                }
                let token = UUID()
                connectionTests[token] = Task {
                    defer { connectionTests.removeValue(forKey: token) }
                    let response: RPCValue
                    do { response = try await Self.testConnection(generator) }
                    catch {
                        if let id = object["id"] {
                            do { try reply(error: BrainRPCError(code: -32003, message: "Connection test: \(error)"), id: id) }
                            catch { events.continuation.yield(.failure(error)) }
                        }
                        return
                    }
                    if let id = object["id"] {
                        do { try peer.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": response])) }
                        catch { events.continuation.yield(.failure(error)) }
                    }
                }
                return
            }
            result = try handle(method, params: params, line: line)
        }
        catch {
            if let id = object["id"] {
                let error = error as? BrainRPCError ?? BrainRPCError(code: -32602, message: "Invalid params: \(error)")
                try reply(error: error, id: id)
            }
            return
        }
        if let id = object["id"] {
            try peer.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        }
    }

    private func handle(_ method: String, params: RPCValue, line: String) throws -> RPCValue {
        switch method {
        case "ping": return .object(["version": .string(NarratorCore.version)])
        case "configure":
            let configuration = try params.decode(RPCConfiguration.self)
            let content = try configuration.makeContent()
            // Reject builtin even when tests supply a generator directly.
            if configuration.generator.kind == .builtin {
                throw BrainRPCError(code: -32001, message: "builtin generator is not supported")
            }
            let generator = try generatorFactory(configuration.generator)
            let settings = try configuration.settings.makeSettings(modelAvailable: generator != nil)
            let url = URL(fileURLWithPath: configuration.dataDirectory, isDirectory: true).standardizedFileURL
            guard directory == nil || directory == url else {
                throw BrainRPCError(code: -32602, message: "dataDirectory cannot change within a session")
            }
            if brain == nil {
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    brain = try SpriteBrain(sensor: RPCSensor(peer), overlay: RPCOverlay(peer), host: RPCHost(peer),
                                            saidURL: url.appendingPathComponent("said.json"))
                } catch { throw BrainRPCError(code: -32000, message: "Data directory: \(error)") }
                directory = url
                brain!.start()
            }
            brain!.configure(settings: settings, content: content, generator: .success(generator))
            return .null
        case "snapshot":
            struct Params: Decodable { let snapshot: ContextSnapshot; let windowID: UInt32; let change: ContextChange }
            let p = try params.decode(Params.self)
            try configured().snapshot(p.snapshot, windowID: p.windowID, change: p.change)
            return .null
        case "windowFrameChanged":
            struct Params: Decodable { let frame: CGRect }
            try configured().windowFrameChanged(params.decode(Params.self).frame)
            return .null
        case "windowChanged": try configured().windowChanged(); return .null
        case "layout.sizeTier": return try RPCLayout.sizeTier(params)
        case "layout.place": return try RPCLayout.place(params)
        case "matchRules":
            // T19's standalone spike keeps its original Foundation geometry contract.
            let response = try BrainRPC.handle(Data(line.utf8))
            guard let response else { return .null }
            let value = try JSONDecoder().decode(RPCValue.self, from: response)
            guard case .object(let object) = value else { preconditionFailure() }
            if let error = object["error"] { throw try error.decode(BrainRPCError.self) }
            return object["result"]!
        default: throw BrainRPCError(code: -32601, message: "Method not found")
        }
    }

    private static func testConnection(_ generator: any TextGenerator) async throws -> RPCValue {
        let start = ContinuousClock.now
        let json = try await generator.generateJSON(system: nil, prompt: "Return JSON with ok set to true.",
            schema: #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#,
            maxTokens: 1024)
        struct Reply: Decodable { let ok: Bool }
        guard try JSONDecoder().decode(Reply.self, from: Data(json.utf8)).ok else {
            throw ProviderConfigurationError.invalidResponse
        }
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        return .object(["elapsedMilliseconds": .number(Decimal(milliseconds))])
    }

    private func configured() throws -> SpriteBrain {
        guard let brain else { throw BrainRPCError(code: -32002, message: "configure is required before events") }
        return brain
    }

    private func reply(error: BrainRPCError, id: RPCValue) throws {
        try peer.send(.object(["jsonrpc": .string("2.0"), "id": id, "error": try .encode(error)]))
    }
}
