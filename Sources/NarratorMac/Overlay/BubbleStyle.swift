import CoreGraphics
import Foundation
import NarratorCore

public enum BubbleShape: String, CaseIterable, Sendable {
    case text, rounded, cloud, speech, sticker, note
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
    // Default is the "glimpse": a small line of text with no bubble behind it, gone after a few seconds.
    public var shape: BubbleShape = .text
    public var size: BubbleSize = .small
    public var theme: ColorTheme = .clear
    public var textEffects: TextEffects = [.outline, .shadow]
    public var animation: BubbleAnimation = .fade
    public var emojiDensity: EmojiDensity = .moderate
    public var font: FontChoice = .persona
    public var dwell: Dwell = .seconds(3)
    public var maxOnScreen = 3

    public init() {}
}
