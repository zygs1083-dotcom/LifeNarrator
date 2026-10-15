import Foundation

public struct DownloadableModel: Codable, Sendable {
    public let name: String
    public let url: URL
    public let size: Int64
    public let sha256: String
    public var filename: String { url.lastPathComponent }
}

public enum ModelCatalog {
    public static let models: [DownloadableModel] = {
        let url = Bundle.module.url(forResource: "models", withExtension: "json")!
        return try! JSONDecoder().decode([DownloadableModel].self, from: Data(contentsOf: url))
    }()
}
