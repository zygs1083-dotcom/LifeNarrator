import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum TargetCategory: String, Sendable {
    case rule, name, deadline, money, action, revisit
}

public struct SpriteTarget: Sendable {
    public var category: TargetCategory
    public var lineIndex: Int
    public var range: Range<String.Index>
    public var text: String
    public var score: Int
    public var candidate: Candidate?

    public init(category: TargetCategory, lineIndex: Int, range: Range<String.Index>, text: String,
                score: Int, candidate: Candidate? = nil) {
        self.category = category; self.lineIndex = lineIndex; self.range = range
        self.text = text; self.score = score; self.candidate = candidate
    }
}

public enum SpriteScout {
    private static let bases: [TargetCategory: Int] = [.rule: 10, .name: 7, .deadline: 6, .money: 6, .action: 5]
    private static let name = regex(#"^[一-鿿·]{2,4}$|^(?:[A-Z][a-z]+\s?){1,3}$"#)
    private static let deadline = regex(#"截止|到期|(?<![\p{L}\p{N}])(?:deadline|ddl|due)(?![\p{L}\p{N}])"#)
    private static let time = regex(#"\d{1,2}[:：]\d{2}|\d{1,4}[-/.年]\d{1,2}([-/.月]\d{1,2}日?)?|今天|明天|后天|今晚|周[一二三四五六日天]|星期.|(?<![\p{L}\p{N}])(?:today|tomorrow|tonight|mon|tue|wed|thu|fri|sat|sun)(?![\p{L}\p{N}])"#)
    private static let money = regex(#"[¥￥$€£]\s?\d[\d,]*(\.\d{1,2})?|\d[\d,]*(\.\d{1,2})?\s?(?:万元|元|块|亿|美元|(?:usd|cny|rmb|dollars?)(?![\p{L}\p{N}]))"#)
    private static let action = regex(#"购买|下单|支付|付款|结算|提交|发送|删除|确认|订阅|续费|加入购物车|立即|开通|(?<![\p{L}\p{N}])(?:buy|pay|checkout|submit|send|delete|confirm|subscribe|renew|place order|add to cart|upgrade)(?![\p{L}\p{N}])"#)

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static func first(_ regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { Range($0.range, in: text)! }
    }

    public static func targets(in snapshot: ContextSnapshot, candidates: [Candidate], memory: SpriteMemory,
                               level: Liveliness) -> [SpriteTarget] {
        let heights = snapshot.textLines.map(\.rect.height).filter { (8...60).contains($0) }.sorted()
        let median: CGFloat = heights.isEmpty ? 0 : (heights[(heights.count - 1) / 2] + heights[heights.count / 2]) / 2
        var targets: [SpriteTarget] = []
        func add(_ category: TargetCategory, index: Int, range: Range<String.Index>, text: String, candidate: Candidate? = nil) {
            let key = SpriteMemory.Key(bundleId: snapshot.bundleId, text: text)
            let status = memory.status(key: key, now: snapshot.capturedAt)
            if status?.isMarked == true { return }
            var score = bases[category]!
            if index >= 0 {
                let rect = RuleMatcher.estimatedRect(for: snapshot.textLines[index], range: range)
                if median > 0 && rect.height >= 1.3 * median { score += 1 }
                if snapshot.contentFrame.width > 700 && rect.minX < snapshot.contentFrame.minX + 0.2 * snapshot.contentFrame.width { score -= 2 }
            }
            score -= max(0, (text.count - 20 + 19) / 20)
            if category == .rule || score >= (level == .rowdy ? 3 : 4) {
                targets.append(SpriteTarget(category: category, lineIndex: index, range: range, text: text, score: score, candidate: candidate))
            }
        }

        for candidate in candidates {
            if let index = candidate.lineIndex, let range = candidate.matchRange {
                add(.rule, index: index, range: range, text: String(snapshot.textLines[index].text[range]), candidate: candidate)
            } else if candidate.rule.kind == .person || candidate.rule.kind == .topic,
                      let hit = RuleMatcher.matchingLines(for: candidate.rule, in: snapshot).first(where: {
                          candidate.rule.match.region != .header || RuleMatcher.isHeader(snapshot.textLines[$0.index].rect, in: snapshot.contentFrame)
                      }) {
                add(.rule, index: hit.index, range: hit.range, text: String(snapshot.textLines[hit.index].text[hit.range]), candidate: candidate)
            } else if let title = snapshot.windowTitle, let index = snapshot.textLines.firstIndex(where: { normalized($0.text) == normalized(title) }) {
                let text = snapshot.textLines[index].text
                add(.rule, index: index, range: text.startIndex..<text.endIndex, text: text, candidate: candidate)
            } else {
                let text = candidate.matchedText ?? snapshot.windowTitle ?? snapshot.appName
                add(.rule, index: -1, range: text.startIndex..<text.endIndex, text: text, candidate: candidate)
            }
        }

        if level != .quiet {
            // A row of short names in the header is a navigation bar, not a chat partner.
            let headerNames = snapshot.textLines.filter {
                RuleMatcher.isHeader($0.rect, in: snapshot.contentFrame) && first(name, in: $0.text) != nil
            }.count
            for (index, line) in snapshot.textLines.enumerated() {
                let folded = FoldedLine(line.text)
                let text = folded.text
                if line.rect.minY < snapshot.contentFrame.minY || line.role == .field || line.rect.height < 10
                    || snapshot.sensitiveRects.contains(where: { $0.insetBy(dx: -60, dy: -60).intersects(line.rect) })
                    || !SpritePrompt.privacyRanges(in: line.text).isEmpty || text.isEmpty { continue }
                func whole(_ category: TargetCategory) {
                    add(category, index: index, range: line.text.startIndex..<line.text.endIndex, text: line.text)
                }
                func substring(_ category: TargetCategory, _ range: Range<String.Index>) {
                    let original = folded.originalRange(range)
                    add(category, index: index, range: original, text: String(line.text[original]))
                }
                for part in text.split(whereSeparator: { "，。！？；、,!?;\n".contains($0) }) {
                    if first(deadline, in: String(part)) != nil && first(time, in: String(part)) != nil {
                        let start = part.startIndex
                        let end = text.index(start, offsetBy: min(30, part.count))
                        substring(.deadline, start..<end)
                        break
                    }
                }
                if let match = first(money, in: text) { substring(.money, match) }
                if headerNames <= 2 && RuleMatcher.isHeader(line.rect, in: snapshot.contentFrame) && first(name, in: line.text) != nil { whole(.name) }
                let actionLimit = line.text.unicodeScalars.contains(where: isCJK) ? 12 : 24
                if (line.role == .button || line.role == .link) && (2...actionLimit).contains(text.count)
                    && first(action, in: text) != nil { whole(.action) }
            }
        }

        targets.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = $0.lineIndex >= 0 ? snapshot.textLines[$0.lineIndex].rect : .zero
            let b = $1.lineIndex >= 0 ? snapshot.textLines[$1.lineIndex].rect : .zero
            if a.height != b.height { return a.height > b.height }
            if a.minY != b.minY { return a.minY < b.minY }
            return $0.lineIndex < $1.lineIndex
        }
        var seen = Set<String>()
        return targets.filter { seen.insert(normalized($0.text)).inserted }
    }

    public static func isMediaFullScreen(_ snapshot: ContextSnapshot) -> Bool {
        snapshot.fullScreen && (snapshot.textSource == .ocr || snapshot.textLines.filter {
            $0.rect.minY >= snapshot.contentFrame.minY && $0.rect.height >= 10
        }.count <= 12)
    }
}
