import Foundation
import NarratorCore

@MainActor final class RPCSensor: BrainSensor {
    let peer: RPCPeer
    init(_ peer: RPCPeer) { self.peer = peer }
    func isTyping(now: Date) async throws -> Bool {
        try await peer.request("sensor.isTyping", .object(["now": try .encode(now)]))
    }
    func isSecureFocused() async throws -> Bool { try await peer.request("sensor.isSecureFocused") }
    func idleSeconds() async -> TimeInterval { await peer.required("sensor.idleSeconds") }
    func lastTypedAt() async -> Date { await peer.required("sensor.lastTypedAt") }
    func isLowPowerMode() async -> Bool { await peer.required("sensor.isLowPowerMode") }
    func refresh() async { let _: RPCNull = await peer.required("sensor.refresh") }
    func boundsProbe() async throws -> Bool { try await peer.request("sensor.boundsProbe") }
    func windowImage(windowID: UInt32, windowFrame: CGRect, redactions: [CGRect]) async throws -> Data {
        struct Params: Encodable { let windowID: UInt32; let windowFrame: CGRect; let redactions: [CGRect] }
        struct Image: Decodable { let jpeg: String }
        do {
            let image: Image = try await peer.request("sensor.windowImage", try .encode(Params(
                windowID: windowID, windowFrame: windowFrame, redactions: redactions)))
            guard let data = Data(base64Encoded: image.jpeg), !data.isEmpty else { throw ProviderConfigurationError.invalidResponse }
            return data
        } catch let error as BrainRPCError where error.code == -32005 {
            throw WindowImageError.windowUnavailable
        }
    }
    func startVisualLines() async { let _: RPCNull = await peer.required("sensor.startVisualLines") }
    func textRect(lineIndex: Int, range: NSRange) async throws -> (rect: CGRect, kind: RectKind)? {
        struct Hit: Decodable { let rect: CGRect; let kind: RectKind }
        let hit: Hit? = try await peer.request("sensor.textRect", rangeParams(lineIndex, range))
        return hit.map { ($0.rect, $0.kind) }
    }
    func markTrack(lineIndex: Int, kind: RectKind?) async throws -> String? {
        try await peer.request("sensor.markTrack", .object(["lineIndex": .number(Decimal(lineIndex)),
            "kind": kind.map { .string($0.rawValue) } ?? .null]))
    }
    func unframedRect(lineIndex: Int, range: NSRange) async -> CGRect {
        await peer.required("sensor.unframedRect", rangeParams(lineIndex, range))
    }
    func placementLine(lineIndex: Int, rect: CGRect, kind: RectKind?) async -> CGRect {
        struct Params: Encodable { let lineIndex: Int; let rect: CGRect; let kind: RectKind? }
        // Encoding fixed, finite port values cannot fail; transport/remote errors remain session failures.
        return await peer.required("sensor.placementLine", try! .encode(Params(lineIndex: lineIndex, rect: rect, kind: kind)))
    }
    func placementObstacles(in contentFrame: CGRect) async -> [CGRect] {
        await peer.required("sensor.placementObstacles", .object(["contentFrame": try! .encode(contentFrame)]))
    }
    private func rangeParams(_ index: Int, _ range: NSRange) -> RPCValue {
        .object(["lineIndex": .number(Decimal(index)), "range": .object([
            "location": .number(Decimal(range.location)), "length": .number(Decimal(range.length))])])
    }
}

@MainActor final class RPCOverlay: BrainOverlay {
    let peer: RPCPeer
    init(_ peer: RPCPeer) { self.peer = peer }
    func show(_ narration: Narration) async -> (shown: Bool, placement: String) {
        struct Shown: Decodable, Sendable { let shown: Bool; let placement: String }
        let result: Shown = await peer.required("overlay.show", .object(["narration": try! .encode(narration)]))
        return (result.shown, result.placement)
    }
    func dismissAll() async { let _: RPCNull = await peer.required("overlay.dismissAll") }
    func follow() async { let _: RPCNull = await peer.required("overlay.follow") }
    func highlight(id: String) async -> CGRect? { await peer.required("overlay.highlight", .object(["id": .string(id)])) }
    func windowFrameChanged(windowID: UInt32, window: WindowGeometry) async {
        let _: RPCNull = await peer.required("overlay.windowFrameChanged", .object([
            "windowID": .number(Decimal(windowID)), "window": try! .encode(window)]))
    }
}

@MainActor final class RPCHost: BrainHost {
    let peer: RPCPeer
    init(_ peer: RPCPeer) { self.peer = peer }
    var ruleSaved: () throws -> Void = {}
    func saveRule(input: String) async throws {
        let _: RPCNull = try await peer.request("host.saveRule", .object(["input": .string(input)]))
        try ruleSaved()
    }
    func applySetting(_ setting: ChatSetting) async throws {
        let _: RPCNull = try await peer.request("host.applySetting", .object(["setting": try .encode(setting)]))
    }
    func report(_ error: any Error) async {
        let value: RPCValue
        if let error = error as? BrainRPCError { value = try! .encode(error) }
        else { value = .object(["code": .number(-32000), "message": .string(String(describing: error))]) }
        let _: RPCNull = await peer.required("host.report", .object(["error": value]))
    }
}
