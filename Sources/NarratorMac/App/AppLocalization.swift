import Foundation

public enum AppLocalization {
    public static func string(_ key: String, language: InterfaceLanguage) -> String {
        let code = language.lang == .zh ? "zh-hans" : "en"
        // SwiftPM lowercases .lproj names; Xcode keeps zh-Hans.
        let name = Bundle.module.localizations.first { $0.lowercased() == code }!
        let bundle = Bundle(path: Bundle.module.path(forResource: name, ofType: "lproj")!)!
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
