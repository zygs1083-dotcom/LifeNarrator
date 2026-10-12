import AppKit
import CoreText
import SwiftUI

public enum BubbleFonts {
    struct FontRef {
        let family: String
        let postScriptName: String
    }

    static let pingFang = FontRef(family: "PingFang SC", postScriptName: "PingFangSC-Regular")

    static func personaFont(_ persona: Persona, language: String) -> NarratorFont {
        switch (persona, language == "zh") {
        case (.sharp, true): .hannotate
        case (.gentle, true): .yuanti
        case (.chuuni, true): .wawati
        case (.sharp, false): .noteworthy
        case (.gentle, false): .chalkboard
        case (.chuuni, false): .markerFelt
        }
    }

    /// Visual-spec §5 fallback chain, most preferred first.
    static func chain(choice: FontChoice, persona: Persona, language: String) -> [FontRef] {
        let first: NarratorFont = switch choice {
        case .persona: personaFont(persona, language: language)
        case .fixed(let font): font
        }
        let fallback: [FontRef] = language == "zh"
            ? [ref(.hanzipen), ref(.yuanti), pingFang]
            : [ref(.chalkboard)]
        return [ref(first)] + fallback
    }

    static func ref(_ font: NarratorFont) -> FontRef {
        FontRef(family: font.family, postScriptName: font.postScriptName)
    }

    /// First installed font of the chain; SF Pro Rounded when none is (always present).
    @MainActor
    public static func font(choice: FontChoice, persona: Persona, language: String, size: CGFloat) -> Font {
        let families = NSFontManager.shared.availableFontFamilies
        if let found = chain(choice: choice, persona: persona, language: language).first(where: { families.contains($0.family) }) {
            return .custom(found.postScriptName, size: size)
        }
        return .system(size: size, design: .rounded)
    }

    /// Asks macOS to download the fonts for this persona (or the fixed font) if missing. Call at launch and on
    /// persona switch; failures are not retried until the next launch.
    public static func requestDownload(choice: FontChoice, persona: Persona) {
        let fonts: [NarratorFont] = switch choice {
        case .persona: [personaFont(persona, language: "zh"), personaFont(persona, language: "en")]
        case .fixed(let font): [font]
        }
        let descriptors = fonts.map {
            CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0.postScriptName] as CFDictionary)
        }
        _ = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { _, _ in true }
    }
}
