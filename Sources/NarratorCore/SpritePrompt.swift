import Foundation

public struct SpriteScreen: Sendable {
    public var lines: [(lineIndex: Int, text: String)]
    public var tokens: Int

    public init(lines: [(lineIndex: Int, text: String)], tokens: Int) {
        self.lines = lines
        self.tokens = tokens
    }

    public var text: String {
        lines.enumerated().map { "\($0.offset)| \($0.element.text)" }.joined(separator: "\n")
    }
}

public enum SpritePrompt {
    private static let privacy = try! NSRegularExpression(
        pattern: #"\S+@\S+\.\S+|\+?\d[\d\s-]{8,}\d|\d{12,}|(?:https?://|www\.)\S+"#)

    public static func privacyRanges(in original: String) -> [Range<String.Index>] {
        let folded = FoldedLine(original)
        return privacy.matches(in: folded.text, range: NSRange(folded.text.startIndex..., in: folded.text)).map {
            folded.originalRange(Range($0.range, in: folded.text)!)
        }
    }

    public static func estimatedTokens(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + (isCJK($1) ? 0.75 : 0.3) }
    }

    public static func screen(in snapshot: ContextSnapshot, budget: Int = 700) -> SpriteScreen {
        var seen = Set<String>()
        let lines: [(lineIndex: Int, text: String)] = snapshot.textLines.enumerated().compactMap { index, line in
            guard line.rect.minY >= snapshot.contentFrame.minY, line.rect.height >= 10, line.role != .field,
                  !snapshot.sensitiveRects.contains(where: { $0.insetBy(dx: -60, dy: -60).intersects(line.rect) }),
                  normalized(line.text).count >= 2, seen.insert(normalized(line.text)).inserted else { return nil }
            var text = line.text
            for range in privacyRanges(in: line.text).reversed() { text.replaceSubrange(range, with: "***") }
            guard text.contains(where: { !$0.isWhitespace && $0 != "*" && !$0.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) } }) else { return nil }
            return (index, text)
        }
        func capped(_ limit: Double) -> [(lineIndex: Int, text: String)] {
            lines.map { line in
                guard estimatedTokens(line.text) > limit else { return line }
                var text = ""
                var tokens = estimatedTokens("…")
                for character in line.text {
                    let cost = estimatedTokens(String(character))
                    if tokens + cost > limit { break }
                    text.append(character)
                    tokens += cost
                }
                return (line.lineIndex, text + "…")
            }
        }
        func total(_ lines: [(lineIndex: Int, text: String)]) -> Int {
            Int(ceil(lines.reduce(0.0) { $0 + estimatedTokens($1.text) + 2 }))
        }
        var output = capped(60)
        if total(output) > budget { output = capped(30) }
        if total(output) > budget {
            output = Array(output.prefix(40))
            while total(output) > budget { output.removeLast() }
        }
        return SpriteScreen(lines: output, tokens: total(output))
    }
}
