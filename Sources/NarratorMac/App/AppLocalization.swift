import Foundation

public enum AppLocalization {
    public static func string(_ key: String, language: InterfaceLanguage) -> String {
        let code = language.lang == .zh ? "zh-hans" : "en"
        let bundle = Bundle(path: Bundle.module.path(forResource: code, ofType: "lproj")!)!
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
