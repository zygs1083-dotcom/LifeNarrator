import Foundation
import NarratorCore

public struct ContextChange: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case appChanged, windowChanged, hostChanged, contentChanged }
    public let appChanged: Bool
    public let windowChanged: Bool
    public let hostChanged: Bool
    public init(appChanged: Bool, windowChanged: Bool, hostChanged: Bool) {
        self.appChanged = appChanged
        self.windowChanged = windowChanged
        self.hostChanged = hostChanged
    }
    public var reason: Reason { appChanged ? .appChanged : windowChanged ? .windowChanged : hostChanged ? .hostChanged : .contentChanged }
}

public enum RectKind: String, Codable, Sendable { case bounds, estimated, ocr }

/// One narration to display. Rects are screen coordinates with a top-left origin (visual-spec §8).
public struct Narration: Codable, Sendable {
    /// Quip instance id; a rule firing twice yields two ids so both bubbles animate separately.
    public var id: String
    /// Identifies the quip text itself; drives the fixed sticker/note tilt.
    public var quipID: String
    public var ruleID: String
    /// Quip ordinal within the rule, for the §3.5 color-group pick.
    public var sequence: Int
    public var text: String
    public var emoji: [String]
    /// "zh" or "en".
    public var language: String
    public var persona: Persona
    /// Rect of the hit text to box, before the §7 expansion. nil for an app-level bubble.
    public var anchor: CGRect?
    public var framed: Bool
    public var line: CGRect?
    public var obstacles: [CGRect]
    public var windowID: UInt32
    public var trackID: String?
    public var window: WindowGeometry

    public init(id: String, quipID: String, ruleID: String, sequence: Int, text: String, emoji: [String], language: String, persona: Persona, anchor: CGRect?, windowID: UInt32, window: WindowGeometry, framed: Bool = true, line: CGRect? = nil, obstacles: [CGRect] = [], trackID: String? = nil) {
        self.id = id
        self.quipID = quipID
        self.ruleID = ruleID
        self.sequence = sequence
        self.text = text
        self.emoji = emoji
        self.language = language
        self.persona = persona
        self.anchor = anchor
        self.framed = framed
        self.line = line
        self.obstacles = obstacles
        self.windowID = windowID
        self.trackID = trackID
        self.window = window
    }
}
