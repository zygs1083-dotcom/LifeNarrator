import Foundation
import NarratorCore
#if canImport(NarratorLlama)
import NarratorLlama
#endif

@MainActor public final class BrainRPCServer {
    private enum Event: Sendable { case line(String), failure(any Error) }
    private let peer: RPCPeer
    private let events = AsyncStream<Event>.makeStream()
    private let generatorFactory: (RPCGeneratorConfiguration) throws -> (any TextGenerator)?
    private var connectionTests: [UUID: Task<Void, Never>] = [:]
    private var brain: SpriteBrain?
    private var directory: URL?
    private var lastSnapshot: ContextSnapshot?
    private var lastWindowID: UInt32?
    private var configuration: RPCConfiguration?
    private var generator: (any TextGenerator)?
    private var spriteName = ""
    #if canImport(NarratorLlama)
    private var builtin: LlamaGenerator?
    private var modelRelease: Task<Void, Never>?
    #endif

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
        do { try await process(lines: lines) }
        catch { await closeGenerator(); throw error }
        await closeGenerator()
    }

    private func closeGenerator() async {
        #if canImport(NarratorLlama)
        await builtin?.close()
        await modelRelease?.value
        builtin = nil
        #endif
    }

    #if canImport(NarratorLlama)
    private func releaseBuiltin() {
        if let previous = builtin {
            let pending = modelRelease
            let generation = brain?.modelCompletion
            modelRelease = Task { await pending?.value; await generation?.value; await previous.close() }
            builtin = nil
        }
    }
    #endif

    private func process(lines: AsyncThrowingStream<String, any Error>) async throws {
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
            brain?.onStateChange = nil
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
            if ["testConnection", "chat.send", "rules.compile"].contains(method) {
                let operation = try asyncOperation(method, params: params)
                let token = UUID()
                connectionTests[token] = Task {
                    defer { connectionTests.removeValue(forKey: token) }
                    do {
                        let response = try await operation()
                        if let id = object["id"] {
                            try peer.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": response]))
                        }
                    } catch is CancellationError where method == "chat.send" {
                        if let id = object["id"] {
                            do { try peer.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .null])) }
                            catch { events.continuation.yield(.failure(error)) }
                        }
                    } catch {
                        if let id = object["id"] {
                            let failure = error as? BrainRPCError ?? BrainRPCError(
                                code: error is CocoaError ? -32000 : (method == "testConnection" ? -32003 : -32004), message: String(describing: error))
                            do { try reply(error: failure, id: id) }
                            catch { events.continuation.yield(.failure(error)) }
                        }
                    }
                }
                return
            }
            result = try handle(method, params: params, line: line)
            #if canImport(NarratorLlama)
            // The host can delete the old GGUF after this reply; ports must still dispatch while it closes.
            if method == "configure", let release = modelRelease, let id = object["id"] {
                let token = UUID()
                connectionTests[token] = Task {
                    defer { connectionTests.removeValue(forKey: token) }
                    await release.value
                    guard !Task.isCancelled else { return }
                    do { try peer.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])) }
                    catch { events.continuation.yield(.failure(error)) }
                }
                return
            }
            #endif
        }
        catch {
            if let id = object["id"] {
                let error = error as? BrainRPCError ?? BrainRPCError(code: error is CocoaError ? -32000 : -32602, message: "Invalid params: \(error)")
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
            let settings = try configuration.settings.makeSettings(modelAvailable: configuration.generator.kind != .none,
                vision: configuration.generator.kind == .api && configuration.generator.vision == true)
            let url = URL(fileURLWithPath: configuration.dataDirectory, isDirectory: true).standardizedFileURL
            guard directory == nil || directory == url else {
                throw BrainRPCError(code: -32602, message: "dataDirectory cannot change within a session")
            }
            #if canImport(NarratorLlama)
            let generator = configuration.generator.kind == .builtin
                ? try configuration.generator.makeGenerator { self.releaseBuiltin(); return self.modelRelease }
                : try generatorFactory(configuration.generator)
            #else
            let generator = try generatorFactory(configuration.generator)
            #endif
            if brain == nil {
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let nameURL = url.appendingPathComponent("sprite-name.json")
                    if FileManager.default.fileExists(atPath: nameURL.path) {
                        spriteName = try JSONDecoder().decode(String.self, from: Data(contentsOf: nameURL))
                    }
                    let host = RPCHost(peer)
                    host.ruleSaved = { [unowned self] in try self.brain!.recordGrowth(.rule) }
                    brain = try SpriteBrain(sensor: RPCSensor(peer), overlay: RPCOverlay(peer), host: host,
                                            saidURL: url.appendingPathComponent("said.json"))
                } catch { throw BrainRPCError(code: -32000, message: "Data directory: \(error)") }
                directory = url
                brain!.onStateChange = { [weak self] in self?.stateChanged() }
                brain!.start()
            }
            self.configuration = configuration
            self.generator = generator
            #if canImport(NarratorLlama)
            if configuration.generator.kind != .builtin { releaseBuiltin() }
            builtin = generator as? LlamaGenerator
            #endif
            brain!.configure(settings: settings, content: content, generator: .success(generator))
            return .null
        case "snapshot":
            struct Params: Decodable { let snapshot: ContextSnapshot; let windowID: UInt32; let change: ContextChange }
            let p = try params.decode(Params.self)
            let brain = try configured()
            if p.snapshot.pid != configuration!.settings.ownProcessID {
                lastSnapshot = p.snapshot
                lastWindowID = p.windowID
            }
            brain.snapshot(p.snapshot, windowID: p.windowID, change: p.change)
            return .null
        case "windowFrameChanged":
            struct Params: Decodable { let frame: CGRect }
            try configured().windowFrameChanged(params.decode(Params.self).frame)
            return .null
        case "windowChanged": try configured().windowChanged(); return .null
        case "chat.history": return try .encode(configured().chat.turns)
        case "memory.list": return try .encode(configured().memories)
        case "memory.add":
            struct Params: Decodable { let kind: Memory.Kind; let text: String }
            let p = try params.decode(Params.self)
            return try .encode(configured().addMemory(kind: p.kind, text: p.text))
        case "memory.edit", "memory.pin", "memory.delete":
            struct Params: Decodable { let id: UUID; let kind: Memory.Kind?; let text: String?; let pinned: Bool? }
            let p = try params.decode(Params.self), brain = try configured()
            guard brain.memories.contains(where: { $0.id == p.id }) else {
                throw BrainRPCError(code: -32602, message: "Unknown memory id")
            }
            switch method {
            case "memory.edit":
                guard let kind = p.kind, let text = p.text else {
                    throw BrainRPCError(code: -32602, message: "memory.edit requires kind and text")
                }
                try brain.editMemory(id: p.id, kind: kind, text: text)
            case "memory.pin":
                guard let pinned = p.pinned else { throw BrainRPCError(code: -32602, message: "memory.pin requires pinned") }
                try brain.pinMemory(id: p.id, pinned: pinned)
            default: try brain.deleteMemory(id: p.id)
            }
            return .null
        case "memory.clear": try configured().clearMemories(); return .null
        case "growth.state": return try companionState()
        case "growth.setName":
            struct Params: Decodable { let name: String }
            let name = try params.decode(Params.self).name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard try configured().growthState.unlocked.contains(.spriteName) else {
                throw BrainRPCError(code: -32602, message: "Sprite names unlock at Lv.2")
            }
            do { try JSONEncoder().encode(name).write(to: directory!.appendingPathComponent("sprite-name.json"), options: .atomic) }
            catch { throw BrainRPCError(code: -32000, message: "Sprite name: \(error)") }
            spriteName = name
            stateChanged()
            return .null
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

    private func stateChanged() {
        do { try peer.send(.object(["jsonrpc": .string("2.0"), "method": .string("host.stateChanged"), "params": .object([:])])) }
        catch { events.continuation.yield(.failure(error)) }
    }

    private func companionState() throws -> RPCValue {
        let state = try configured().growthState, lang = configuration!.settings.lang
        struct Unlock: Encodable { let id: GrowthUnlock; let level: Int; let name: String }
        struct State: Encodable {
            let state: GrowthState; let name: String; let title: String
            let nextLevelExperience: Int?; let daysKnown: Int; let unlocks: [Unlock]
        }
        return try .encode(State(state: state, name: spriteName, title: state.title(lang: lang),
            nextLevelExperience: state.nextLevelExperience, daysKnown: state.daysKnown(now: Date()),
            unlocks: GrowthUnlock.allCases.map { Unlock(id: $0, level: $0.level, name: $0.name(lang: lang)) }))
    }

    private func asyncOperation(_ method: String, params: RPCValue) throws -> () async throws -> RPCValue {
        if method == "testConnection" {
            struct Params: Decodable { let generator: RPCGeneratorConfiguration }
            let configuration = try params.decode(Params.self).generator
            guard configuration.kind == .api, let generator = try generatorFactory(configuration) else {
                throw BrainRPCError(code: -32602, message: "testConnection requires an API generator")
            }
            return {
                let testGenerator: any TextGenerator
                if configuration.vision == true {
                    guard let imageGenerator = generator as? any ImageTextGenerator else { throw WindowImageError.unsupportedGenerator }
                    testGenerator = imageGenerator.attachingJPEG(WindowImage.connectionTestJPEG)
                } else { testGenerator = generator }
                return try await Self.testConnection(testGenerator)
            }
        }
        let brain = try configured()
        if method == "chat.send" {
            struct Params: Decodable { let text: String; let narration: String?; let includeScreen: Bool }
            let p = try params.decode(Params.self)
            guard !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrainRPCError(code: -32602, message: "Chat text cannot be empty")
            }
            let snapshot = lastSnapshot, windowID = lastWindowID
            return {
                let context = try await brain.chatContext(snapshot: snapshot, windowID: windowID, narration: p.narration)
                return try .encode(await brain.sendChat(p.text, context: context, includeScreen: p.includeScreen))
            }
        }
        struct Params: Decodable { let input: String }
        let p = try params.decode(Params.self), configuration = configuration!, generator = generator
        return {
            let rule: Rule
            if let generator {
                rule = try await RuleCompiler.compile(input: p.input, lang: configuration.settings.lang, now: Date(),
                    generator: generator, resolveBundleIds: Self.resolveBundleIds)
            } else {
                rule = try RuleCompiler.compileWithoutModel(input: p.input, pack: RuleLoader.loadBuiltin(), now: Date())
            }
            return try .encode(rule)
        }
    }

    nonisolated private static func resolveBundleIds(_ names: [String]) -> [String] { [] }

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
