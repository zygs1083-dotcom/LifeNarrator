import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    (0x3400...0x9FFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
}

public func isUsableAlias(_ alias: String) -> Bool {
    let text = normalized(alias)
    return text.count >= (text.unicodeScalars.contains(where: isCJK) ? 2 : 3)
}

// Keep original indices because folding and collapsed whitespace can change string length.
private struct SearchText {
    var value = ""
    var spans: [Range<String.Index>] = []
    init(_ original: String) {
        var pendingSpace: Range<String.Index>?
        for index in original.indices {
            let end = original.index(after: index)
            let character = original[index]
            if character.isWhitespace {
                if let start = pendingSpace?.lowerBound { pendingSpace = start..<end }
                else { pendingSpace = index..<end }
                continue
            }
            if let pendingSpace, !value.isEmpty { value.append(" "); spans.append(pendingSpace) }
            pendingSpace = nil
            let folded = String(character).folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            value += folded
            spans += folded.map { _ in index..<end }
        }
    }
    func range(of alias: String, cjk: Bool) -> Range<String.Index>? {
        let pattern = NSRegularExpression.escapedPattern(for: alias)
        let range = cjk ? value.range(of: alias) : value.range(of: "(?<![\\p{L}\\p{N}])\(pattern)(?![\\p{L}\\p{N}])", options: .regularExpression)
        guard let range else { return nil }
        let start = value.distance(from: value.startIndex, to: range.lowerBound)
        let end = value.distance(from: value.startIndex, to: range.upperBound)
        return spans[start].lowerBound..<spans[end - 1].upperBound
    }
}

public struct Candidate: Sendable {
    public var rule: Rule
    public var matchedText: String?
    public var lineIndex: Int?
    public var matchRange: Range<String.Index>?
    public init(rule: Rule, matchedText: String? = nil, lineIndex: Int? = nil, matchRange: Range<String.Index>? = nil) {
        self.rule = rule; self.matchedText = matchedText; self.lineIndex = lineIndex; self.matchRange = matchRange
    }
}

public struct RuleMatcher: Sendable {
    private struct PreparedRule: Sendable {
        var rule: Rule
        var aliases: [String]
    }
    private var rules: [PreparedRule]
    public init(rules: [Rule], disabledBuiltinIds: Set<String> = []) {
        self.rules = rules.filter { $0.enabled && !disabledBuiltinIds.contains($0.id) }.map {
            PreparedRule(rule: $0, aliases: ($0.match.aliases ?? []).filter(isUsableAlias).map(normalized))
        }
    }

    public func candidates(in snapshot: ContextSnapshot, now: Date, appChanged: Bool, hostChanged: Bool,
                           calendar: Calendar = .current) -> [Candidate] {
        let title = snapshot.windowTitle.map(SearchText.init)
        let lines = snapshot.textLines.map { SearchText($0.text) }
        var seen: Set<String> = []
        var candidates: [Candidate] = []
        for prepared in rules {
            let rule = prepared.rule
            if seen.contains(rule.id) { continue }
            let candidate: Candidate?
            switch rule.kind {
            case .app:
                let matches = (rule.match.bundleIds ?? []).contains { $0.caseInsensitiveCompare(snapshot.bundleId) == .orderedSame }
                    || (rule.match.appNames ?? []).contains { normalized($0) == normalized(snapshot.appName) }
                candidate = appChanged && matches ? Candidate(rule: rule) : nil
            case .site:
                let matches = snapshot.host.map { host in
                    (rule.match.domains ?? []).contains { domain in
                        let d = domain.lowercased()
                        return host.lowercased() == d || host.lowercased().hasSuffix("." + d)
                    }
                } ?? false
                candidate = hostChanged && matches ? Candidate(rule: rule) : nil
            case .time:
                candidate = appChanged && rule.match.when!.contains(now, calendar: calendar) ? Candidate(rule: rule) : nil
            case .person, .topic:
                candidate = textCandidate(prepared, title: title, lines: lines, snapshot: snapshot)
            }
            if let candidate { candidates.append(candidate); seen.insert(rule.id) }
        }
        let priorities: [RuleKind: Int] = [.person: 0, .topic: 1, .site: 2, .app: 3, .time: 4]
        return candidates.sorted {
            if $0.rule.kind != $1.rule.kind { return priorities[$0.rule.kind]! < priorities[$1.rule.kind]! }
            return ($0.rule.createdAt ?? .distantPast) > ($1.rule.createdAt ?? .distantPast)
        }
    }

    private func textCandidate(_ prepared: PreparedRule, title: SearchText?, lines: [SearchText],
                               snapshot: ContextSnapshot) -> Candidate? {
        let rule = prepared.rule
        if let title, let text = snapshot.windowTitle {
            for alias in prepared.aliases {
                if let range = title.range(of: alias, cjk: alias.unicodeScalars.contains(where: isCJK)) {
                    return Candidate(rule: rule, matchedText: String(text[range]))
                }
            }
        }
        // In a tall window the header band can reach the first messages; the topmost hit is the conversation title.
        let order = rule.match.region == .header
            ? lines.indices.sorted { snapshot.textLines[$0].rect.minY < snapshot.textLines[$1].rect.minY }
            : Array(lines.indices)
        for index in order {
            let line = lines[index]
            if rule.match.region == .header && !Self.isHeader(snapshot.textLines[index].rect, in: snapshot.contentFrame) { continue }
            for alias in prepared.aliases {
                if let range = line.range(of: alias, cjk: alias.unicodeScalars.contains(where: isCJK)) {
                    return Candidate(rule: rule, matchedText: String(snapshot.textLines[index].text[range]), lineIndex: index, matchRange: range)
                }
            }
        }
        return nil
    }

    public static func isHeader(_ rect: CGRect, in content: CGRect) -> Bool {
        let height = min(160, max(80, content.height * 0.18))
        return rect.minY >= content.minY && rect.minY <= content.minY + height
            && rect.minX >= content.minX + content.width * 0.25 && rect.height >= 12
    }

    public static func matchingLines(for rule: Rule, in snapshot: ContextSnapshot) -> [(index: Int, range: Range<String.Index>)] {
        let aliases = (rule.match.aliases ?? []).filter(isUsableAlias).map(normalized)
        return snapshot.textLines.enumerated().compactMap { index, line in
            let search = SearchText(line.text)
            for alias in aliases {
                if let range = search.range(of: alias, cjk: alias.unicodeScalars.contains(where: isCJK)) { return (index, range) }
            }
            return nil
        }
    }

    public static func estimatedRect(for line: TextLine, range: Range<String.Index>) -> CGRect {
        func weight(_ text: Substring) -> CGFloat {
            CGFloat(text.reduce(0) { total, character in
                total + (character.unicodeScalars.contains { isCJK($0) || (0xFF01...0xFF60).contains($0.value) || (0xFFE0...0xFFE6).contains($0.value) } ? 2 : 1)
            })
        }
        let total = weight(line.text[...])
        let prefix = weight(line.text[..<range.lowerBound])
        let matched = weight(line.text[range])
        return CGRect(x: line.rect.minX + line.rect.width * prefix / total, y: line.rect.minY,
                      width: line.rect.width * matched / total, height: line.rect.height)
    }

    public static func highlightRect(for candidate: Candidate, in snapshot: ContextSnapshot) -> CGRect? {
        guard candidate.rule.highlight else { return nil }
        if let index = candidate.lineIndex, let range = candidate.matchRange {
            return estimatedRect(for: snapshot.textLines[index], range: range)
        }
        guard let hit = matchingLines(for: candidate.rule, in: snapshot).first else { return nil }
        return estimatedRect(for: snapshot.textLines[hit.index], range: hit.range)
    }
}
