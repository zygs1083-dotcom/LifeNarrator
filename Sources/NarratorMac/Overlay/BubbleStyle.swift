import CoreGraphics
import Foundation
import NarratorCore

public enum BubbleShape: String, CaseIterable, Sendable {
    case rounded, cloud, speech, sticker, note
}

/// Art-text effects of visual-spec §4; they stack.
public struct TextEffects: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let outline = TextEffects(rawValue: 1)
    public static let shadow = TextEffects(rawValue: 2)
    public static let gradient = TextEffects(rawValue: 4)
}

public enum BubbleAnimation: String, CaseIterable, Sendable {
    case fade, bounce, slide, pop
}

public enum EmojiDensity: String, CaseIterable, Sendable {
    case none, moderate, many
}

public enum Persona: String, CaseIterable, Sendable {
    case sharp, gentle, chuuni
}

/// The seven system fonts of visual-spec §5. PostScript names are the spec's; confirm on a Mac with
/// `NSFontManager.shared.availableMembers(ofFontFamily:)`.
public enum NarratorFont: String, CaseIterable, Sendable {
    case hannotate, yuanti, wawati, hanzipen, noteworthy, chalkboard, markerFelt

    public var family: String {
        switch self {
        case .hannotate: "Hannotate SC"
        case .yuanti: "Yuanti SC"
        case .wawati: "Wawati SC"
        case .hanzipen: "Hanzipen SC"
        case .noteworthy: "Noteworthy"
        case .chalkboard: "Chalkboard SE"
        case .markerFelt: "Marker Felt"
        }
    }

    public var postScriptName: String {
        switch self {
        case .hannotate: "HannotateSC-W5"
        case .yuanti: "YuantiSC-Regular"
        case .wawati: "WawaSC-Regular"
        case .hanzipen: "HanziPenSC-W5"
        case .noteworthy: "Noteworthy-Bold"
        case .chalkboard: "ChalkboardSE-Regular"
        case .markerFelt: "MarkerFelt-Wide"
        }
    }
}

/// Coordinator decision 7: follow the persona, or one fixed font for both languages.
public enum FontChoice: Sendable, Equatable {
    case persona
    case fixed(NarratorFont)
}

public enum Dwell: Sendable, Equatable {
    case seconds(TimeInterval)
    /// Coordinator decision 6: stays until any key press or mouse click anywhere.
    case untilDismissed
}

public struct BubbleStyle: Sendable {
    public var shape: BubbleShape = .rounded
    public var size: BubbleSize = .medium
    public var theme: ColorTheme = .macaron
    public var textEffects: TextEffects = [.outline, .shadow]
    public var animation: BubbleAnimation = .fade
    public var emojiDensity: EmojiDensity = .moderate
    public var font: FontChoice = .persona
    public var dwell: Dwell = .seconds(6)
    public var maxOnScreen = 3

    public init() {}
}

/// One narration to display. Rects are screen coordinates with a top-left origin (visual-spec §8).
public struct Narration: Sendable {
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
    public var windowID: CGWindowID
    public var window: WindowGeometry

    public init(id: String, quipID: String, ruleID: String, sequence: Int, text: String, emoji: [String], language: String, persona: Persona, anchor: CGRect?, windowID: CGWindowID, window: WindowGeometry) {
        self.id = id
        self.quipID = quipID
        self.ruleID = ruleID
        self.sequence = sequence
        self.text = text
        self.emoji = emoji
        self.language = language
        self.persona = persona
        self.anchor = anchor
        self.windowID = windowID
        self.window = window
    }
}
