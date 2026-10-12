import Foundation
import NarratorCore

enum TextGeometry {
    // Each of the 64 bits compares adjacent samples in a 9 × 8 grayscale image.
    static func dHash(_ pixels: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where pixels[y * 9 + x] > pixels[y * 9 + x + 1] {
                hash |= UInt64(1) << (y * 8 + x)
            }
        }
        return hash
    }

    static func screenRect(_ normalized: CGRect, in window: CGRect) -> CGRect {
        CGRect(x: window.minX + normalized.minX * window.width,
               y: window.minY + (1 - normalized.maxY) * window.height,
               width: normalized.width * window.width, height: normalized.height * window.height)
    }

    static func trimmedText(_ raw: String) -> (text: String, utf16Offset: Int) {
        let start = raw.firstIndex { !$0.isWhitespace } ?? raw.endIndex
        let trimmed = raw[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(trimmed.prefix(200)), raw[..<start].utf16.count)
    }

    static func sortedIndices(_ lines: [TextLine]) -> [Int] {
        struct Key: Hashable {
            let text: String
            let x: CGFloat
            let y: CGFloat
            let width: CGFloat
            let height: CGFloat
        }
        var seen: Set<Key> = []
        let indices = lines.indices.filter { !lines[$0].text.isEmpty }.sorted {
            let a = lines[$0].rect, b = lines[$1].rect
            if a.minY != b.minY { return a.minY < b.minY }
            if a.minX != b.minX { return a.minX < b.minX }
            return $0 < $1
        }
        return Array(indices.filter {
            let line = lines[$0]
            return seen.insert(Key(text: line.text, x: line.rect.minX, y: line.rect.minY,
                                   width: line.rect.width, height: line.rect.height)).inserted
        }.prefix(300))
    }
}
