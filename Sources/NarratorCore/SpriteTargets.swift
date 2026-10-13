import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum TargetCategory: String, Sendable {
    case rule, name, alert, deadline, money, action, question, stat, emphasis, heading, revisit
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
    private static let stopwords = Set("文件 编辑 显示 窗口 帮助 格式 工具 视图 插入 设置 搜索 取消 确定 关闭 返回 更多 菜单 首页 发现 我的 消息 通讯录 工作台 收藏 历史 下载 全部 筛选 排序 刷新 登录 注册 file edit view window help format tools insert settings search cancel ok close back more menu home discover me messages contacts favorites history downloads all filter sort refresh".split(separator: " ").map(String.init) + ["log in", "sign in", "sign up"])
    private static let codeApps: Set<String> = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.googlecode.iterm2"]
    private static let bases: [TargetCategory: Int] = [.rule: 10, .name: 7, .alert: 7, .deadline: 6, .money: 6,
                                                    .action: 5, .question: 5, .stat: 4, .emphasis: 4, .heading: 3]
    private static let name = regex(#"^[一-鿿·]{2,4}$|^(?:[A-Z][a-z]+\s?){1,3}$"#)
    private static let privacy = regex(#"\S+@\S+\.\S+|\+?\d[\d\s-]{8,}\d|\d{12,}|https?://|www\."#)
    private static let code = regex(#"^(?://|#|import|func|let|var|def|class)"#)
    private static let alert = regex(#"错误|失败|异常|警告|无法|崩溃|超时|拒绝|过期|欠费|(?<![\p{L}\p{N}])(?:error|failed|failure|exception|warning|crash|timed? ?out|denied|expired|unpaid|401|403|404|500|502|503)(?![\p{L}\p{N}])"#)
    private static let deadline = regex(#"截止|到期|之前|前提交|(?<![\p{L}\p{N}])(?:deadline|ddl|due|by)(?![\p{L}\p{N}])"#)
    private static let time = regex(#"\d{1,2}[:：]\d{2}|\d{1,4}[-/.年]\d{1,2}([-/.月]\d{1,2}日?)?|今天|明天|后天|今晚|周[一二三四五六日天]|星期.|(?<![\p{L}\p{N}])(?:today|tomorrow|tonight|mon|tue|wed|thu|fri|sat|sun)(?![\p{L}\p{N}])"#)
    private static let money = regex(#"[¥￥$€£]\s?\d[\d,]*(\.\d{1,2})?|\d[\d,]*(\.\d{1,2})?\s?(?:万元|元|块|亿|美元|(?:usd|cny|rmb|dollars?)(?![\p{L}\p{N}]))"#)
    private static let action = regex(#"购买|下单|支付|付款|结算|提交|发送|删除|确认|订阅|续费|加入购物车|立即|开通|(?<![\p{L}\p{N}])(?:buy|pay|checkout|submit|send|delete|confirm|subscribe|renew|place order|add to cart|upgrade)(?![\p{L}\p{N}])"#)
    private static let stat = regex(#"(?:\d{1,3}([,，]\d{3})+|\d+(\.\d+)?\s?(?:%|％|万|亿|[km]\b))(?:\s?(?:次|人|条|个|点赞|评论|粉丝|播放|阅读|(?:views?|likes?|followers|comments?|stars?)(?![\p{L}\p{N}])))?"#)
    private static let emphasis = regex(#"紧急|重要|立刻|马上|(?<![\p{L}\p{N}])(?:urgent|important|asap)(?![\p{L}\p{N}])"#)
    private static let capitals = regex(#"\b[A-Z]{4,}\b"#)
    private static let punctuation = CharacterSet(charactersIn: "，。！？；、,.!?;\n")

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static func first(_ regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { Range($0.range, in: text)! }
    }

    // Folding and whitespace collapse must keep the ranges in the original AX/OCR text.
    private struct FoldedLine {
        var text = ""
        var spans: [Range<String.Index>] = []
        init(_ original: String) {
            var space: Range<String.Index>?
            for index in original.indices {
                let end = original.index(after: index)
                let character = original[index]
                if character.isWhitespace {
                    space = (space?.lowerBound ?? index)..<end
                    continue
                }
                if let space, !text.isEmpty { text += " "; spans.append(space) }
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

    private static func clause(around match: Range<String.Index>, in text: String) -> Range<String.Index> {
        func isPunctuation(_ c: Character) -> Bool { c.unicodeScalars.contains { punctuation.contains($0) } }
        var start = match.lowerBound
        var end = match.upperBound
        while start > text.startIndex {
            let previous = text.index(before: start)
            if isPunctuation(text[previous]) { break }
            start = previous
        }
        while end < text.endIndex && !isPunctuation(text[end]) { end = text.index(after: end) }
        while start < end && text[start].isWhitespace { start = text.index(after: start) }
        while start < end && text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        if text.distance(from: start, to: end) > 30 {
            start = max(start, text.index(match.upperBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex)
            end = text.index(start, offsetBy: 30)
        }
        return start..<end
    }

    public static func targets(in snapshot: ContextSnapshot, candidates: [Candidate], memory: SpriteMemory,
                               onScreen: [SpriteTarget], level: Liveliness) -> [SpriteTarget] {
        let heights = snapshot.textLines.map(\.rect.height).filter { (8...60).contains($0) }.sorted()
        let median: CGFloat = heights.isEmpty ? 0 : (heights[(heights.count - 1) / 2] + heights[heights.count / 2]) / 2
        var targets: [SpriteTarget] = []
        func add(_ category: TargetCategory, index: Int, range: Range<String.Index>, text: String, candidate: Candidate? = nil) {
            let key = SpriteMemory.Key(bundleId: snapshot.bundleId, text: text)
            let status = memory.status(key: key, now: snapshot.capturedAt)
            if status?.isMarked == true || (category != .rule && status?.declined == true) { return }
            var score = bases[category]!
            if index >= 0 {
                let rect = RuleMatcher.estimatedRect(for: snapshot.textLines[index], range: range)
                if median > 0 && rect.height >= 1.3 * median { score += 1 }
                if snapshot.contentFrame.width > 700 && rect.minX < snapshot.contentFrame.minX + 0.2 * snapshot.contentFrame.width { score -= 2 }
            }
            score -= max(0, (text.count - 20 + 19) / 20)
            if onScreen.contains(where: { $0.category == category }) { score -= 2 }
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
            for (index, line) in snapshot.textLines.enumerated() {
                let folded = FoldedLine(line.text)
                let text = folded.text
                if line.rect.minY < snapshot.contentFrame.minY || line.role == .field || line.rect.height < 10
                    || snapshot.sensitiveRects.contains(where: { $0.insetBy(dx: -60, dy: -60).intersects(line.rect) })
                    || first(privacy, in: text) != nil || stopwords.contains(text) || text.isEmpty { continue }
                let isCode = codeApps.contains(snapshot.bundleId) || first(code, in: text) != nil
                    || text.filter { "{}();=<>".contains($0) }.count >= 3
                let long = line.text.unicodeScalars.contains(where: isCJK) ? text.count > 60 : text.count > 120
                func whole(_ category: TargetCategory) {
                    add(category, index: index, range: line.text.startIndex..<line.text.endIndex, text: line.text)
                }
                func substring(_ category: TargetCategory, _ range: Range<String.Index>) {
                    let original = folded.originalRange(range)
                    add(category, index: index, range: original, text: String(line.text[original]))
                }
                if let match = first(alert, in: text) { substring(.alert, clause(around: match, in: text)) }
                if isCode { continue }
                if let match = first(deadline, in: text) {
                    let range = clause(around: match, in: text)
                    if first(time, in: String(text[range])) != nil { substring(.deadline, range) }
                }
                if let match = first(money, in: text) { substring(.money, match) }
                if let match = first(stat, in: text) { substring(.stat, match) }
                if long { continue }
                if RuleMatcher.isHeader(line.rect, in: snapshot.contentFrame) && first(name, in: line.text) != nil { whole(.name) }
                let actionLimit = line.text.unicodeScalars.contains(where: isCJK) ? 12 : 24
                if (line.role == .button || line.role == .link) && (2...actionLimit).contains(text.count)
                    && first(action, in: text) != nil { whole(.action) }
                if (4...40).contains(text.count) && text.hasSuffix("?") { whole(.question) }
                if text.count <= 40 && (text.hasSuffix("!") || first(emphasis, in: text) != nil || first(capitals, in: line.text) != nil) { whole(.emphasis) }
                if median > 0 && line.rect.height >= 1.4 * median && (2...30).contains(text.count)
                    && !text.hasSuffix(".") && !text.hasSuffix("。") { whole(.heading) }
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
        snapshot.fullScreen && (snapshot.textSource == .ocr || targets(in: snapshot, candidates: [], memory: SpriteMemory(), onScreen: [], level: .rowdy).count <= 6)
    }

    public static func diverse(_ targets: [SpriteTarget], in snapshot: ContextSnapshot, count: Int) -> [SpriteTarget] {
        var selected: [SpriteTarget] = []
        for target in targets {
            if selected.count == count { break }
            if selected.contains(where: { $0.category == target.category }) { continue }
            if target.lineIndex >= 0 {
                let line = snapshot.textLines[target.lineIndex]
                let rect = BubblePlacement.spriteFrame(around: RuleMatcher.estimatedRect(for: line, range: target.range))
                if selected.contains(where: {
                    guard $0.lineIndex >= 0 else { return false }
                    let other = BubblePlacement.spriteFrame(around: RuleMatcher.estimatedRect(for: snapshot.textLines[$0.lineIndex], range: $0.range))
                    return abs(rect.minY - other.minY) < 24 || rect.insetBy(dx: -8, dy: -8).intersects(other.insetBy(dx: -8, dy: -8))
                }) { continue }
            }
            selected.append(target)
        }
        return selected
    }
}
