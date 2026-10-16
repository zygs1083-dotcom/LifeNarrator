import Foundation

public enum SpriteLocator {
    public struct Position: Sendable {
        public let lineIndex: Int
        public let rect: CGRect?

        public init(lineIndex: Int, rect: CGRect?) {
            self.lineIndex = lineIndex
            self.rect = rect
        }
    }

    public static func conflicts(_ position: Position, with others: [Position]) -> Bool {
        others.contains { other in
            if position.lineIndex >= 0 && position.lineIndex == other.lineIndex { return true }
            guard let rect = position.rect, let otherRect = other.rect else { return false }
            return abs(rect.midY - otherRect.midY) < 24
        }
    }

    public static func locate(quote: String, lineHint: Int, in lines: [TextLine])
        -> (lineIndex: Int, range: Range<String.Index>)? {
        let quote = FoldedLine(quote, joiningCJK: true).text
        guard !quote.isEmpty else { return nil }
        func find(_ index: Int) -> (lineIndex: Int, range: Range<String.Index>)? {
            let line = FoldedLine(lines[index].text, joiningCJK: true)
            guard let range = line.text.range(of: quote) else { return nil }
            return (index, line.originalRange(range))
        }
        if lines.indices.contains(lineHint), let hit = find(lineHint) { return hit }
        return lines.indices.sorted {
            if lines[$0].text.count != lines[$1].text.count { return lines[$0].text.count < lines[$1].text.count }
            return $0 < $1
        }.lazy.compactMap(find).first
    }
}
