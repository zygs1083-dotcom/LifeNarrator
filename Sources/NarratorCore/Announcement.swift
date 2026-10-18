import Foundation

public struct UpdateAnnouncement: Decodable, Sendable {
    public struct Text: Decodable, Sendable {
        public let zh: String
        public let en: String
        public func value(_ language: Lang) -> String { language == .zh ? zh : en }
    }
    public let title: Text
    public let intro: Text
    public let items: [Text]
    public let dismiss: Text

    public static func load() throws -> Self {
        let url = Bundle.module.url(forResource: "announcement", withExtension: "json")!
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public static func shouldShow(onboardingCompleted: Bool, seenVersion: String?) -> Bool {
        onboardingCompleted && seenVersion != NarratorCore.version
    }
}
