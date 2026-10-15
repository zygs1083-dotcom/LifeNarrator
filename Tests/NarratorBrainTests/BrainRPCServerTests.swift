import Foundation
import Testing
import NarratorCore
@testable import NarratorBrain

private extension RPCValue {
    subscript(_ key: String) -> RPCValue? { if case .object(let o) = self { o[key] } else { nil } }
}

private actor RPCGenerator: TextGenerator {
    var prompts: [String] = []
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        prompts.append(prompt)
        return #"{"marks":[{"l":0,"q":"first phrase","t":"咖啡还没凉","e":"🌷"}]}"#
    }
}

private actor ConnectionGenerator: TextGenerator {
    let reply: String
    let gate: AsyncStream<Void>
    var prompt: String?
    var maxTokens: Int?
    init(reply: String, gate: AsyncStream<Void>) { self.reply = reply; self.gate = gate }
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        self.prompt = prompt; self.maxTokens = maxTokens
        for await _ in gate { break }
        try Task.checkCancellation()
        return reply
    }
}

@MainActor private final class ScriptedShell {
    let input = AsyncThrowingStream<String, any Error>.makeStream()
    var output: [RPCValue] = []
    let written = AsyncStream<RPCValue>.makeStream()
    var script: [String: RPCValue] = [:]
    var remoteError: String?

    func send(_ method: String, params: RPCValue = .object([:]), id: RPCValue? = .number(1)) throws {
        var object: [String: RPCValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
        object["id"] = id
        input.continuation.yield(try RPCValue.object(object).line())
    }

    func waitFor(_ method: String) async {
        for await value in written.stream {
            if value["method"] == .string(method) { return }
        }
    }

    func waitForReply(_ id: RPCValue) async {
        for await value in written.stream where value["id"] == id && value["method"] == nil { return }
    }

    func write(_ line: String) throws {
        let value = try JSONDecoder().decode(RPCValue.self, from: Data(line.utf8))
        output.append(value)
        written.continuation.yield(value)
        guard case .string(let method) = value["method"] else { return }
        let result: RPCValue
        switch method {
        case "sensor.isTyping", "sensor.isSecureFocused", "sensor.isLowPowerMode": result = .bool(false)
        case "sensor.boundsProbe": result = .bool(true)
        case "sensor.idleSeconds": result = .number(0)
        case "sensor.lastTypedAt": result = .string("2020-01-01T00:00:00Z")
        case "sensor.textRect": result = .object(["rect": try .encode(CGRect(x: 120, y: 100, width: 120, height: 20)), "kind": .string("bounds")])
        case "sensor.markTrack": result = .string("opaque-track")
        case "sensor.unframedRect": result = try .encode(CGRect(x: 120, y: 100, width: 120, height: 20))
        case "sensor.placementLine": result = try #require(value["params"]?["rect"])
        case "sensor.placementObstacles": result = .array([])
        case "overlay.highlight": result = .null
        case "overlay.show": result = .object(["shown": .bool(true), "placement": .string("right")])
        case "sensor.refresh", "sensor.startVisualLines", "overlay.dismissAll", "overlay.follow", "overlay.windowFrameChanged", "host.report": result = .null
        default: Issue.record("Unexpected method \(method)"); return
        }
        var reply: [String: RPCValue] = ["jsonrpc": .string("2.0"), "id": try #require(value["id"])]
        if remoteError == method {
            reply["error"] = .object(["code": .number(42), "message": .string("shell failed")])
        } else { reply["result"] = script[method] ?? result }
        input.continuation.yield(try RPCValue.object(reply).line())
    }
}

@MainActor private func configuration(directory: URL, kind: String = "none") throws -> RPCValue {
    var object: [String: RPCValue] = [
        "settings": .object(["liveliness": .string("lively"), "markGap": .number(0), "paused": .bool(false),
            "blacklist": .array([]), "persona": .string("gentle"), "lang": .string("zh"),
            "disabledBuiltinIds": .array([]), "maxOnScreen": .number(8), "ownProcessID": .number(999), "memoryEnabled": .bool(true)]),
        "rules": .array([]), "customPersonas": .array([]),
        "generator": .object(["kind": .string(kind)]), "dataDirectory": .string(directory.path)]
    if kind == "api" {
        object["generator"] = .object(["kind": .string("api"), "presetId": .string("openai"),
            "model": .string("fixture"), "key": .string("test-key")])
    }
    return .object(object)
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct BrainRPCServerScenarios {
    @Test(arguments: [#"{"ok":true}"#, #"{"ok":false}"#, "invalid JSON"])
    func connectionTestValidatesReplyAndDoesNotBlockRPC(_ response: String) async throws {
        let shell = ScriptedShell()
        let gate = AsyncStream<Void>.makeStream()
        let generator = ConnectionGenerator(reply: response, gate: gate.stream)
        let server = BrainRPCServer(writeLine: shell.write, generatorFactory: { _ in generator })
        let task = Task { try await server.run(lines: shell.input.stream) }
        try shell.send("testConnection", params: .object(["generator": .object([
            "kind": .string("api"), "presetId": .string("openai"), "model": .string("fixture"), "key": .string("test-key")])]), id: .number(10))
        try shell.send("ping", id: .number(11))
        await shell.waitForReply(.number(11))
        #expect(!shell.output.contains { $0["id"] == .number(10) })
        #expect(await generator.prompt == "Return JSON with ok set to true.")
        #expect(await generator.maxTokens == 1024)
        gate.continuation.yield(())
        await shell.waitForReply(.number(10))
        let result = try #require(shell.output.first { $0["id"] == .number(10) })
        if response == #"{"ok":true}"# {
            #expect(result["result"]?["elapsedMilliseconds"] != nil)
        } else { #expect(result["error"]?["code"] == .number(-32003)) }
        #expect(!shell.output.contains { $0["method"] != nil })
        shell.input.continuation.finish()
        try await task.value
    }

    @Test func configureSnapshotGeneratesAndShowsThroughLineStreams() async throws {
        let shell = ScriptedShell(), generator = RPCGenerator()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = BrainRPCServer(writeLine: shell.write, generatorFactory: { _ in generator })
        let task = Task { try await server.run(lines: shell.input.stream) }
        try shell.send("configure", params: configuration(directory: directory, kind: "api"))
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let snapshot = ContextSnapshot(bundleId: "fixture", appName: "Fixture", pid: 1,
            windowFrame: frame, contentFrame: frame,
            textLines: [TextLine(text: "🌷 quoted first phrase", rect: CGRect(x: 100, y: 100, width: 300, height: 20))],
            textSource: .ax, capturedAt: Date())
        try shell.send("snapshot", params: .object(["snapshot": try .encode(snapshot), "windowID": .number(7),
            "change": try .encode(ContextChange(appChanged: true, windowChanged: true, hostChanged: false))]))
        await shell.waitFor("overlay.show")
        #expect(await generator.prompts.count == 1)
        let show = try #require(shell.output.first { $0["method"] == .string("overlay.show") })
        let narration = try #require(show["params"]?["narration"])
        #expect(narration["text"] == .string("咖啡还没凉"))
        #expect(narration["windowID"] == .number(7))
        #expect(narration["trackID"] == .string("opaque-track"))
        #expect(narration["anchor"]?["x"] == .number(120))
        let rect = try #require(shell.output.first { $0["method"] == .string("sensor.textRect") })
        #expect(rect["params"]?["range"] == .object(["location": .number(10), "length": .number(12)]))
        try shell.send("windowFrameChanged", params: .object(["frame": try .encode(frame.offsetBy(dx: 10, dy: 0))]))
        await shell.waitFor("overlay.windowFrameChanged")
        try shell.send("windowChanged")
        shell.input.continuation.finish()
        try await task.value
        #expect(!shell.output.contains { $0["method"] == .string("host.report") })
    }

    @Test func errorsUnknownMethodsNotificationsAndEOF() async throws {
        var output: [RPCValue] = []
        let server = BrainRPCServer { output.append(try JSONDecoder().decode(RPCValue.self, from: Data($0.utf8))) }
        let input = AsyncThrowingStream<String, any Error>.makeStream()
        for line in ["{", "[]", #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"unknown"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"snapshot","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"windowChanged"}"#,
            #"{"jsonrpc":"2.0","method":"unknown"}"#,
            #"{"jsonrpc":"2.0","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"中文","method":"ping"}"#] { input.continuation.yield(line) }
        input.continuation.finish()
        try await server.run(lines: input.stream)
        #expect(output.compactMap { $0["error"]?["code"] } == [-32700, -32600, -32600, -32601, -32602, -32002].map { .number(Decimal($0)) })
        #expect(output.last?["id"] == .string("中文"))
        #expect(output.last?["result"]?["version"] == .string(NarratorCore.version))
        #expect(output[6]["id"] == .number(9_007_199_254_740_993))
        #expect(output.count == 8)
    }

    @Test func configureRejectsBuiltinInvalidProviderAndDirectoryChanges() throws {
        var output: [RPCValue] = []
        let server = BrainRPCServer { output.append(try JSONDecoder().decode(RPCValue.self, from: Data($0.utf8))) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func call(_ params: RPCValue) throws {
            try server.receive(RPCValue.object(["jsonrpc": .string("2.0"), "id": .number(1),
                "method": .string("configure"), "params": params]).line())
        }
        try call(configuration(directory: directory, kind: "builtin"))
        #expect(output.last?["error"]?["code"] == .number(-32001))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        var bad = try configuration(directory: directory, kind: "api").decode([String: RPCValue].self)
        bad["generator"] = .object(["kind": .string("api"), "presetId": .string("unknown"), "model": .string("m"), "key": .string("")])
        try call(.object(bad))
        #expect(output.last?["error"]?["code"] == .number(-32602))
        try call(configuration(directory: directory))
        #expect(output.last?["result"] == .null)
        try call(configuration(directory: directory.appendingPathComponent("different")))
        #expect(output.last?["error"]?["code"] == .number(-32602))
    }

    @Test func requiredPortErrorTerminatesSession() async throws {
        let shell = ScriptedShell()
        shell.remoteError = "overlay.dismissAll"
        let server = BrainRPCServer(writeLine: shell.write)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try shell.send("configure", params: configuration(directory: directory))
        do { try await server.run(lines: shell.input.stream); Issue.record("Expected terminal error") }
        catch let error as BrainRPCError { #expect(error.code == 42); #expect(error.message == "shell failed") }
    }

    @Test func providerFactoryUsesExistingClients() throws {
        func make(_ json: String) throws -> (any TextGenerator)? {
            try JSONDecoder().decode(RPCGeneratorConfiguration.self, from: Data(json.utf8)).makeGenerator()
        }
        #expect(try make(#"{"kind":"none"}"#) == nil)
        let openAI = try #require(try make(#"{"kind":"api","presetId":"openai","model":"m","baseURL":"http://localhost:1234/v1","structured":"prompt","key":"k"}"#) as? OpenAIChatClient)
        #expect(openAI.model == "m" && openAI.key == "k" && openAI.structured == .prompt)
        #expect(openAI.baseURL.absoluteString == "http://localhost:1234/v1")
        #expect(try make(#"{"kind":"api","presetId":"anthropic","model":"m","key":"k"}"#) is AnthropicClient)
        #expect(throws: (any Error).self) { try make(#"{"kind":"api","presetId":"openai","model":"","key":"k"}"#) }
        #expect(throws: (any Error).self) { try make(#"{"kind":"api","presetId":"openai","model":"m","baseURL":"file:///tmp","key":"k"}"#) }
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct RPCPortScenarios {
    @Test func concurrentRequestsMatchOutOfOrderRepliesAndRemoteErrors() async throws {
        let sent = AsyncStream<RPCValue>.makeStream()
        var messages = sent.stream.makeAsyncIterator()
        let peer = RPCPeer { sent.continuation.yield(try JSONDecoder().decode(RPCValue.self, from: Data($0.utf8))) }
        defer { peer.close() }
        let sensor = RPCSensor(peer)
        let first = Task { try await sensor.isTyping(now: Date(timeIntervalSince1970: 0)) }
        let second = Task { try await sensor.isSecureFocused() }
        let requests = [try #require(await messages.next()), try #require(await messages.next())]
        let typing = try #require(requests.first { $0["method"] == .string("sensor.isTyping") })
        let secure = try #require(requests.first { $0["method"] == .string("sensor.isSecureFocused") })
        #expect(typing["params"]?["now"] == .string("1970-01-01T00:00:00Z"))
        try peer.receive(["id": #require(secure["id"]), "result": .bool(true)])
        try peer.receive(["id": #require(typing["id"]), "result": .bool(false)])
        #expect(try await first.value == false)
        #expect(try await second.value == true)
        let failure = Task { try await sensor.boundsProbe() }
        let failed = try #require(await messages.next())
        try peer.receive(["id": #require(failed["id"]), "error": .object([
            "code": .number(17), "message": .string("permission denied"), "data": .string("uia")])])
        do { _ = try await failure.value; Issue.record("Expected remote error") }
        catch let error as BrainRPCError { #expect(error.code == 17); #expect(error.data == .string("uia")) }
        let cancelled = Task { try await sensor.isSecureFocused() }
        let cancelledRequest = try #require(await messages.next())
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try peer.receive(["id": #require(cancelledRequest["id"]), "result": .bool(true)])
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct RPCAdapterRoundTrips {
    @Test func allPortMethodsPreserveArgumentsAndResults() async throws {
        let shell = ScriptedShell()
        let peer = RPCPeer(writeLine: shell.write)
        let replies = Task {
            for try await line in shell.input.stream {
                try peer.receive(JSONDecoder().decode([String: RPCValue].self, from: Data(line.utf8)))
            }
        }
        defer { shell.input.continuation.finish(); peer.close() }
        let sensor = RPCSensor(peer), overlay = RPCOverlay(peer), host = RPCHost(peer)
        let rect = CGRect(x: -25, y: 100, width: 120, height: 20)
        #expect(try await sensor.isTyping(now: Date()) == false)
        #expect(try await sensor.isSecureFocused() == false)
        #expect(await sensor.idleSeconds() == 0)
        #expect(await sensor.lastTypedAt() == Date(timeIntervalSince1970: 1_577_836_800))
        #expect(await sensor.isLowPowerMode() == false)
        await sensor.refresh()
        #expect(try await sensor.boundsProbe())
        await sensor.startVisualLines()
        let hit = try await sensor.textRect(lineIndex: 3, range: NSRange(location: 2, length: 4))
        #expect(hit?.kind == .bounds)
        #expect(try await sensor.markTrack(lineIndex: 3, kind: .ocr) == "opaque-track")
        _ = await sensor.unframedRect(lineIndex: 3, range: NSRange(location: 2, length: 4))
        #expect(await sensor.placementLine(lineIndex: 3, rect: rect, kind: .estimated) == rect)
        #expect(await sensor.placementObstacles(in: rect) == [])
        #expect(await overlay.highlight(id: "bubble") == nil)
        await overlay.dismissAll()
        await overlay.follow()
        let window = WindowGeometry(frame: rect, chromeHeight: 12)
        await overlay.windowFrameChanged(windowID: 42, window: window)
        let narration = Narration(id: "n", quipID: "q", ruleID: "r", sequence: 2, text: "你好", emoji: ["🌷"],
            language: "zh", persona: .gentle, anchor: rect, windowID: 42, window: window)
        #expect(await overlay.show(narration).shown)
        await host.report(BrainRPCError(code: 17, message: "permission denied"))
        let frameChange = try #require(shell.output.first { $0["method"] == .string("overlay.windowFrameChanged") })
        #expect(frameChange["params"]?["window"]?["frame"] == (try .encode(rect)))
        let range = try #require(shell.output.first { $0["method"] == .string("sensor.textRect") })
        #expect(range["params"]?["lineIndex"] == .number(3))
        #expect(range["params"]?["range"] == .object(["location": .number(2), "length": .number(4)]))
        #expect(shell.output.last?["params"]?["error"]?["code"] == .number(17))
        shell.script["sensor.textRect"] = .null
        shell.script["sensor.markTrack"] = .null
        #expect(try await sensor.textRect(lineIndex: 0, range: NSRange(location: 0, length: 1)) == nil)
        #expect(try await sensor.markTrack(lineIndex: 0, kind: nil) == nil)
        shell.input.continuation.finish()
        try await replies.value
    }
}
