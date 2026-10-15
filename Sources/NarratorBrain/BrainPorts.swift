import Foundation
import NarratorCore

public protocol GeneratorMetrics: Sendable {
    var isBusy: Bool { get async }
    var lastPrefillSeconds: Double { get async }
}

public struct BrainSettings: Sendable {
    public struct SystemOne: Sendable {
        public var model: String
        public var connection: Result<(url: URL, key: String), any Error>

        public init(model: String, connection: Result<(url: URL, key: String), any Error>) {
            self.model = model
            self.connection = connection
        }
    }

    public var liveliness: Liveliness
    public var markGap: TimeInterval
    public var paused: Bool
    public var blacklist: [String]
    public var persona: Persona
    public var lang: Lang
    public var disabledBuiltinIds: Set<String>
    public var maxOnScreen: Int
    public var modelAvailable: Bool
    public var systemOne: SystemOne?
    public var ownProcessID: Int32

    public init(liveliness: Liveliness, markGap: TimeInterval, paused: Bool, blacklist: [String],
                persona: Persona, lang: Lang, disabledBuiltinIds: Set<String>, maxOnScreen: Int,
                modelAvailable: Bool, systemOne: SystemOne?, ownProcessID: Int32) {
        self.liveliness = liveliness
        self.markGap = markGap
        self.paused = paused
        self.blacklist = blacklist
        self.persona = persona
        self.lang = lang
        self.disabledBuiltinIds = disabledBuiltinIds
        self.maxOnScreen = maxOnScreen
        self.modelAvailable = modelAvailable
        self.systemOne = systemOne
        self.ownProcessID = ownProcessID
    }
}

public struct BrainContent: Sendable {
    public var rules: [Rule]
    public var builtin: QuipPack
    public var personas: PersonaCatalog

    public init(rules: [Rule], builtin: QuipPack, personas: PersonaCatalog) {
        self.rules = rules
        self.builtin = builtin
        self.personas = personas
    }
}

@MainActor public protocol BrainSensor: AnyObject {
    func isTyping(now: Date) async throws -> Bool
    func isSecureFocused() async throws -> Bool
    func idleSeconds() async -> TimeInterval
    func lastTypedAt() async -> Date
    func isLowPowerMode() async -> Bool
    func refresh() async
    func boundsProbe() async throws -> Bool
    func startVisualLines() async
    func textRect(lineIndex: Int, range: NSRange) async throws -> (rect: CGRect, kind: RectKind)?
    func markTrack(lineIndex: Int, kind: RectKind?) async throws -> String?
    func unframedRect(lineIndex: Int, range: NSRange) async -> CGRect
    func placementLine(lineIndex: Int, rect: CGRect, kind: RectKind?) async -> CGRect
    func placementObstacles(in contentFrame: CGRect) async -> [CGRect]
}

@MainActor public protocol BrainOverlay: AnyObject {
    func show(_ narration: Narration) async -> (shown: Bool, placement: String)
    func dismissAll() async
    func follow() async
    func highlight(id: String) async -> CGRect?
    func windowFrameChanged(windowID: UInt32, window: WindowGeometry) async
}

@MainActor public protocol BrainHost: AnyObject {
    func report(_ error: any Error) async
}
