import Foundation

// Folding and whitespace collapse must keep the ranges in the original AX/OCR text.
struct FoldedLine {
    var text = ""
    var spans: [Range<String.Index>] = []
    init(_ original: String, joiningCJK: Bool = false) {
        var space: Range<String.Index>?
        for index in original.indices {
            let end = original.index(after: index)
            let character = original[index]
            if character.isWhitespace {
                space = (space?.lowerBound ?? index)..<end
                continue
            }
            // Windows OCR separates CJK characters with spaces that the AX text lacks; quote matching drops spaces touching CJK.
            if let space, !text.isEmpty, !(joiningCJK
                && (text.unicodeScalars.last.map(isCJK) == true || character.unicodeScalars.contains(where: isCJK))) {
                text += " "; spans.append(space)
            }
            space = nil
            let folded = String(character).folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            text += folded
            spans += folded.map { _ in index..<end }
        }
    }
    func originalRange(_ range: Range<String.Index>) -> Range<String.Index> {
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        return spans[start].lowerBound..<spans[end - 1].upperBound
    }
}

