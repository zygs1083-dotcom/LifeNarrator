import Foundation

public enum SpriteLocator {
    public static func locate(quote: String, lineHint: Int, in lines: [TextLine])
        -> (lineIndex: Int, range: Range<String.Index>)? {
        let quote = FoldedLine(quote).text
        guard !quote.isEmpty else { return nil }
        func find(_ index: Int) -> (lineIndex: Int, range: Range<String.Index>)? {
            let line = FoldedLine(lines[index].text)
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
