import Foundation

public struct SemanticVersion: Comparable, Sendable {
    private let numbers: [String]
    private let prerelease: [String]

    public init(_ value: String) throws {
        let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let build = version.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2,
              build.count == 1 || Self.validIdentifiers(String(build[1])) else {
            throw UpdateMetadataError.invalidVersion(value)
        }
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count == 3, numbers.allSatisfy(Self.validNumber) else {
            throw UpdateMetadataError.invalidVersion(value)
        }
        let prerelease = parts.count == 2 ? String(parts[1]) : nil
        if let prerelease {
            guard Self.validIdentifiers(prerelease),
                  prerelease.split(separator: ".").allSatisfy({ !Self.isNumeric(String($0)) || Self.validNumber(String($0)) }) else {
                throw UpdateMetadataError.invalidVersion(value)
            }
        }
        self.numbers = numbers
        self.prerelease = prerelease?.split(separator: ".").map(String.init) ?? []
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right {
            return numericLess(left, right)
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = isNumeric(left), rightNumeric = isNumeric(right)
            if leftNumeric != rightNumeric { return leftNumeric }
            return leftNumeric ? numericLess(left, right) : left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validNumber(_ value: String) -> Bool {
        isNumeric(value) && (value.count == 1 || !value.hasPrefix("0"))
    }

    private static func validIdentifiers(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}

public enum UpdateMetadataError: Error, CustomStringConvertible {
    case invalidVersion(String), invalidChecksum(String), missingAsset(String), invalidURL(String)

    public var description: String {
        switch self {
        case .invalidVersion(let value): "Invalid semantic version: \(value)"
        case .invalidChecksum(let value): "Invalid or missing SHA-256 checksum: \(value)"
        case .missingAsset(let value): "Release is missing \(value)"
        case .invalidURL(let value): "Invalid release URL: \(value)"
        }
    }
}

public enum ReleaseChecksums {
    public static func sha256(for filename: String, in text: String) throws -> String {
        var result: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { throw UpdateMetadataError.invalidChecksum(String(line)) }
            let hash = String(fields[0])
            let filenameField = fields[1].trimmingCharacters(in: .whitespaces)
            let name = filenameField.hasPrefix("*") ? String(filenameField.dropFirst()) : filenameField
            guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw UpdateMetadataError.invalidChecksum(String(line))
            }
            if name == filename {
                guard result == nil else { throw UpdateMetadataError.invalidChecksum("duplicate \(filename)") }
                result = hash.lowercased()
            }
        }
        guard let result else { throw UpdateMetadataError.invalidChecksum(filename) }
        return result
    }
}

public struct AppRelease: Decodable, Sendable {
    public let tag: String
    public let pageURL: URL
    public let assets: [Asset]
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let url: URL
        private enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
    }
    private enum CodingKeys: String, CodingKey { case tag = "tag_name", pageURL = "html_url", assets }

    public static func parse(_ data: Data) throws -> AppRelease {
        let release = try JSONDecoder().decode(Self.self, from: data)
        _ = try SemanticVersion(release.tag)
        try validate(release.pageURL, prefix: "/zygs1083-dotcom/LifeNarrator/releases/")
        return release
    }

    public func assetURL(named name: String) throws -> URL {
        guard let asset = assets.first(where: { $0.name == name }) else { throw UpdateMetadataError.missingAsset(name) }
        try Self.validate(asset.url, prefix: "/zygs1083-dotcom/LifeNarrator/releases/download/")
        return asset.url
    }

    private static func validate(_ url: URL, prefix: String) throws {
        guard url.scheme == "https", url.host == "github.com", url.path.hasPrefix(prefix) else {
            throw UpdateMetadataError.invalidURL(url.absoluteString)
        }
    }
}
