import Foundation

struct CompareArguments {
    enum Failure: Error { case usage }
    let models: [String]
    let draft: String?
    let draftTokens: Int
    let mtp: Bool

    init(_ arguments: [String]) throws {
        var models: [String] = []
        var draft: String?
        var draftTokens = 6
        var mtp = false
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw Failure.usage }
            if option == "--mtp" { mtp = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw Failure.usage }
            let value = arguments[index + 1]
            guard !value.isEmpty, !value.hasPrefix("--") else { throw Failure.usage }
            switch option {
            case "--models":
                models = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard models.allSatisfy({ !$0.isEmpty }) else { throw Failure.usage }
            case "--draft": draft = value
            case "--draft-tokens":
                guard let count = Int(value), (1...8).contains(count) else { throw Failure.usage }
                draftTokens = count
            default: throw Failure.usage
            }
            index += 2
        }
        guard !models.isEmpty, !(mtp && draft != nil),
              !seen.contains("--draft-tokens") || draft != nil else { throw Failure.usage }
        self.models = models
        self.draft = draft
        self.draftTokens = draftTokens
        self.mtp = mtp
    }
}
