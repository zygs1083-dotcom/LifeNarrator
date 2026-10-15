import AppKit
import CoreText
import NarratorCore
import SwiftUI

public enum BubbleFonts {
    struct FontRef {
        let family: String
        let postScriptName: String
    }

    static let pingFang = FontRef(family: "PingFang SC", postScriptName: "PingFangSC-Regular")

    static func chain(choice: FontChoice, persona: Persona, language: String, catalog: PersonaCatalog = .builtin) -> [FontRef] {
        switch choice {
        case .persona:
            return catalog[persona].fonts[language == "zh" ? .zh : .en].map { family in
                if let known = NarratorFont.allCases.first(where: { $0.family == family }) { return ref(known) }
                return FontRef(family: family, postScriptName: family)
            }
        case .fixed(let font):
            return [ref(font)] + (language == "zh" ? [ref(.hanzipen), ref(.yuanti), pingFang] : [ref(.chalkboard)])
        }
    }

    static func ref(_ font: NarratorFont) -> FontRef {
        FontRef(family: font.family, postScriptName: font.postScriptName)
    }

    /// First installed font of the chain; SF Pro Rounded when none is (always present).
    @MainActor
    public static func font(choice: FontChoice, persona: Persona, language: String, size: CGFloat, catalog: PersonaCatalog = .builtin) -> Font {
        let families = NSFontManager.shared.availableFontFamilies
        if let found = chain(choice: choice, persona: persona, language: language, catalog: catalog).first(where: { families.contains($0.family) }) {
            return .custom(found.postScriptName, size: size)
        }
        return .system(size: size, design: .rounded)
    }

    /// Asks macOS to download the fonts for this persona (or the fixed font) if missing. Call at launch and on
    /// persona switch; failures are not retried until the next launch.
    public static func requestDownload(choice: FontChoice, persona: Persona, catalog: PersonaCatalog = .builtin) {
        let fonts = chain(choice: choice, persona: persona, language: "zh", catalog: catalog)
            + chain(choice: choice, persona: persona, language: "en", catalog: catalog)
        let descriptors = fonts.map {
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: $0.family] as CFDictionary)
        }
        _ = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { _, _ in true }
    }
}
