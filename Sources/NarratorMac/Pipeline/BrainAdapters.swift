import AppKit
import NarratorCore
import NarratorBrain

@MainActor
final class MacBrainSensor: BrainSensor {
    let sensor: ContextSensor
    let host: MacBrainHost
    private let screenText = ScreenText()
    var lines: [TextLine] = []
    var tracks: [String: MarkTrack] = [:]

    init(sensor: ContextSensor, host: MacBrainHost) {
        self.sensor = sensor
        self.host = host
    }

    func isTyping(now: Date) async throws -> Bool { try sensor.isTyping(now: now) }
    func isSecureFocused() async throws -> Bool { try sensor.isSecureFocused() }
    func idleSeconds() async -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }
    func lastTypedAt() async -> Date { sensor.lastTypedAt }
    func isLowPowerMode() async -> Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    func refresh() async { sensor.refresh() }
    func boundsProbe() async throws -> Bool { try sensor.boundsProbe() }
    func windowImage(windowID: UInt32, windowFrame: CGRect, redactions: [CGRect]) async throws -> Data {
        try await screenText.windowImage(windowID: windowID, frame: windowFrame, redactions: redactions)
    }
    func startVisualLines() async {
        do { _ = try await sensor.visualLines() }
        catch is CancellationError { return }
        catch { host.reportNow(error) }
    }
    func textRect(lineIndex: Int, range: NSRange) async throws -> (rect: CGRect, kind: RectKind)? {
        try await sensor.textRect(lineIndex: lineIndex, range: Range(range, in: lines[lineIndex].text)!)
    }
    func markTrack(lineIndex: Int, kind: RectKind?) async throws -> String? {
        guard let track = try sensor.markTrack(lineIndex: lineIndex, kind: kind) else { return nil }
        let id = String(lineIndex)
        tracks[id] = track
        return id
    }
    func unframedRect(lineIndex: Int, range: NSRange) async -> CGRect {
        sensor.unframedRect(lineIndex: lineIndex, range: Range(range, in: lines[lineIndex].text)!)
    }
    func placementLine(lineIndex: Int, rect: CGRect, kind: RectKind?) async -> CGRect {
        sensor.placementLine(lineIndex: lineIndex, rect: rect, kind: kind)
    }
    func placementObstacles(in contentFrame: CGRect) async -> [CGRect] { sensor.placementObstacles(in: contentFrame) }
}

@MainActor
final class MacBrainOverlay: BrainOverlay {
    let overlay: OverlayController
    let sensor: MacBrainSensor

    init(overlay: OverlayController, sensor: MacBrainSensor) {
        self.overlay = overlay
        self.sensor = sensor
    }

    func show(_ narration: Narration) async -> (shown: Bool, placement: String) {
        let track = narration.trackID.flatMap { sensor.tracks.removeValue(forKey: $0) }
        let shown = overlay.show(narration, track: track)
        return (shown, overlay.lastPlacement)
    }
    func dismissAll() async { overlay.dismissAll() }
    func follow() async { overlay.follow() }
    func highlight(id: String) async -> CGRect? { overlay.highlight(id: id) }
    func windowFrameChanged(windowID: UInt32, window: WindowGeometry) async { overlay.windowFrameChanged(windowID, to: window) }
}

@MainActor
final class MacBrainHost: BrainHost {
    unowned let store: AppStore
    /// Shown once until the settings change, so every failing request does not raise the alert again.
    var keyRejectedShown = false

    init(store: AppStore) { self.store = store }

    func saveRule(input: String) async throws {
        _ = try await store.compile(input, generator: try store.textGenerator())
    }

    func applySetting(_ setting: ChatSetting) async throws {
        var updated = store.settings
        if let liveliness = setting.liveliness { updated.liveliness = liveliness }
        if let paused = setting.paused { updated.paused = paused }
        if let persona = setting.persona { updated.persona = persona }
        try store.directory.saveSettings(updated)
        store.settings = updated
    }

    func report(_ error: any Error) async { reportNow(error) }

    func reportNow(_ error: any Error) {
        if Task.isCancelled { return }
        if error is ImageCaptureFailure {
            store.error = String(describing: error)
        } else if let failure = error as? AXFailure, failure.code == .apiDisabled {
            store.error = String(describing: error)
        } else if case HTTPClientError.status(let code, let body) = error, code == 401 || code == 403 {
            FileHandle.standardError.write(Data("[sprite] skipped: \(error)\n".utf8))
            if !keyRejectedShown {
                keyRejectedShown = true
                store.error = store.text("api.keyRejected") + "\n\(code): \(body)"
            }
        } else if case HTTPClientError.status(let code, let body) = error, (400..<500).contains(code) {
            store.error = "\(code): \(body)"
        } else {
            FileHandle.standardError.write(Data("[sprite] skipped: \(error)\n".utf8))
        }
    }
}
