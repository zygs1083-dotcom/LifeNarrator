import Foundation

public struct SaidHistory: Codable, Sendable {
    private struct Entry: Codable, Sendable {
        let hashes: [UInt32]
        let time: Date
    }
    private struct Recent: Sendable {
        let text: String
        let time: Date
    }
    private var entries: [Entry] = []
    private var originals: [Recent] = []
    private enum CodingKeys: CodingKey { case entries }

    public init() {}

    public func isRepeat(_ text: String, now: Date) -> Bool {
        let hashes = Self.shingles(text)
        return entries.contains { entry in
            now.timeIntervalSince(entry.time) < 86400 && Self.jaccard(hashes, Set(entry.hashes)) >= 0.5
        }
    }

    public mutating func record(_ text: String, now: Date) {
        entries.removeAll { now.timeIntervalSince($0.time) >= 86400 }
        originals.removeAll { now.timeIntervalSince($0.time) >= 86400 }
        entries.append(Entry(hashes: Self.shingles(text).sorted(), time: now))
        originals.append(Recent(text: text, time: now))
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
        if originals.count > 1000 { originals.removeFirst(originals.count - 1000) }
    }

    public func recent(_ n: Int) -> [String] {
        originals.reversed().prefix(n).map(\.text)
    }

    public static func normalizedText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: true
            default: false
            }
        }))
    }

    public static func textHash(_ text: String) -> UInt32 { fnv1a(normalizedText(text)) }

    static func shingles(_ text: String) -> Set<UInt32> {
        let normalized = normalizedText(text)
        let characters = Array(normalized)
        if characters.count < 3 { return [fnv1a(normalized)] }
        let n = normalized.unicodeScalars.contains(where: isCJK) ? 2 : 3
        return Set((0...(characters.count - n)).map { fnv1a(String(characters[$0..<($0 + n)])) })
    }

    static func jaccard(_ a: Set<UInt32>, _ b: Set<UInt32>) -> Double {
        Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func fnv1a(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(0x811c9dc5)) { ($0 ^ UInt32($1)) &* 0x01000193 }
    }
}
