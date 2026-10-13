import Foundation

public struct CompiledRule: Codable, Sendable {
    public var kind: RuleKind
    public var label: Label
    public var sentiment: Sentiment
    public var note: String
    public var aliases: [String]
    public var domains: [String]
    public var appNames: [String]
    public var highlight: Bool
    public var variables: [String: String]
}

public struct GeneratedQuip: Codable, Sendable {
    public var text: String
    public var emoji: [String]
    public init(text: String, emoji: [String]) { self.text = text; self.emoji = emoji }
}

public enum QuipValidator {
    public static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.contains { $0.value == 0xFE0F } && scalars.contains { $0.properties.isEmoji && $0.value > 0x7F })
            || (scalars.contains { $0.value == 0x20E3 } && scalars.contains { (0x30...0x39).contains($0.value) || $0.value == 0x23 || $0.value == 0x2A })
    }

    public static func validate(_ generated: [GeneratedQuip], rule: Rule, lang: Lang, persona: Persona) -> [Quip] {
        var seen = Set(rule.quips.filter { $0.lang == lang && $0.persona == persona }.map { normalized($0.text) })
        var valid: [Quip] = []
        let placeholders = try! NSRegularExpression(pattern: "\\{([^{}]*)\\}")
        for item in generated {
            var text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A dangling comma reads like a cut-off sentence.
            while let last = text.last, "，,、；;：:".contains(last) { text.removeLast() }
            guard !text.isEmpty, text.count <= (lang == .zh ? 14 : 40), !text.contains(where: isEmoji),
                  (1...3).contains(item.emoji.count), item.emoji.allSatisfy({ $0.count == 1 && isEmoji($0.first!) }) else { continue }
            let matches = placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard matches.allSatisfy({ rule.variables?[String(text[Range($0.range(at: 1), in: text)!])] != nil }) else { continue }
            let key = normalized(text)
            if seen.insert(key).inserted { valid.append(Quip(lang: lang, persona: persona, text: text, emoji: item.emoji)) }
        }
        return valid.count >= 3 ? valid : []
    }
}

public enum GenerationError: Error, Sendable { case invalidCompiledRule(String) }

public enum RuleCompiler {
    public static func assemble(_ compiled: CompiledRule, input: String, now: Date,
                                resolveBundleIds: ([String]) throws -> [String]) throws -> Rule {
        guard compiled.kind != .time, compiled.aliases.count <= 8, compiled.domains.count <= 6,
              compiled.appNames.count <= 4 else { throw GenerationError.invalidCompiledRule("invalid kind or array sizes") }
        let aliases = compiled.aliases.filter(isUsableAlias)
        let match: Match
        switch compiled.kind {
        case .app: match = Match(bundleIds: try resolveBundleIds(compiled.appNames), appNames: compiled.appNames)
        case .site: match = Match(domains: compiled.domains)
        case .person: match = Match(aliases: aliases, region: .header)
        case .topic: match = Match(aliases: aliases, region: .anywhere)
        case .time: preconditionFailure("compiled rules do not include time")
        }
        let rule = Rule(id: UUID().uuidString, kind: compiled.kind, source: .user, input: input, label: compiled.label,
                        sentiment: compiled.sentiment, note: compiled.note, match: match, highlight: compiled.highlight,
                        variables: compiled.variables, createdAt: now)
        try RuleLoader.validate(rule)
        return rule
    }

    public static func compile(input: String, lang: Lang, now: Date,
                               generator: any TextGenerator, resolveBundleIds: ([String]) throws -> [String]) async throws -> Rule {
        let json = try await generator.generateJSON(system: nil, prompt: GenerationPrompts.compile(input: input, lang: lang), schema: GenerationPrompts.compiledRuleSchema)
        let compiled = try JSONDecoder().decode(CompiledRule.self, from: Data(json.utf8))
        return try assemble(compiled, input: input, now: now, resolveBundleIds: resolveBundleIds)
    }

    public static func generateQuips(for rule: Rule, lang: Lang, persona: Persona,
                                     generator: any TextGenerator, n: Int = 12, mood: String? = nil) async throws -> [Quip] {
        struct Batch: Decodable { var quips: [GeneratedQuip] }
        let json = try await generator.generateJSON(system: nil,
            prompt: GenerationPrompts.quips(rule: rule, persona: persona, lang: lang, n: n, mood: mood), schema: GenerationPrompts.quipsSchema)
        let batch = try JSONDecoder().decode(Batch.self, from: Data(json.utf8))
        return QuipValidator.validate(batch.quips, rule: rule, lang: lang, persona: persona)
    }

    public static func compileWithoutModel(input: String, pack: QuipPack, now: Date) throws -> Rule {
        let folded = normalized(input)
        let dislike = ["讨厌", "烦", "怕", "hate", "annoy"].contains { folded.contains($0) }
        let like = ["喜欢", "爱", "like", "love"].contains { folded.contains($0) }
        let sentiment: Sentiment = dislike ? .dislike : like ? .like : .neutral
        let person = ["领导", "老板", "经理", "同事", "老师", "boss", "manager"].contains { folded.contains($0) }
        let stops = ["讨厌", "喜欢", "是我", "我", "的", "烦", "怕", "爱", "hate", "annoyed by", "annoy", "like", "love", "my", "is", "i", "the"]
        func strip(_ text: String) -> String {
            var result = text
            for stop in stops {
                if stop.unicodeScalars.contains(where: isCJK) { result = result.replacingOccurrences(of: stop, with: "", options: .caseInsensitive) }
                else { result = result.replacingOccurrences(of: "(?i)(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: stop))(?![\\p{L}\\p{N}])", with: "", options: .regularExpression) }
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        let label: String
        var kind: RuleKind = .topic
        var match: Match
        func containsName(_ name: String) -> Bool {
            let name = normalized(name)
            if name.unicodeScalars.contains(where: isCJK) { return folded.contains(name) }
            return folded.range(of: "(?<![\\p{Latin}\\p{N}])\(NSRegularExpression.escapedPattern(for: name))(?![\\p{Latin}\\p{N}])", options: .regularExpression) != nil
        }
        if person {
            kind = .person
            let relationship = input.range(of: "是我|是我的|\\bis\\b|\\bmy\\b", options: [.regularExpression, .caseInsensitive])
            label = strip(relationship.map { String(input[..<$0.lowerBound]) } ?? input)
            match = Match(aliases: [label], region: .header)
        } else {
            let keyword = strip(input)
            let knownSite = pack.rules.first { rule in
                rule.kind == .site && ([rule.label.zh, rule.label.en] + (rule.match.domains ?? [])).contains(where: containsName)
            }
            let knownApp = pack.rules.first { rule in
                rule.kind == .app && (rule.match.appNames ?? []).contains(where: containsName)
            }
            if let site = knownSite {
                kind = .site; label = keyword; match = Match(domains: site.match.domains)
            } else if let domainRange = keyword.range(of: "(?:[a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}", options: .regularExpression) {
                kind = .site; label = String(keyword[domainRange]); match = Match(domains: [label.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)])
            } else if let app = knownApp {
                kind = .app; label = keyword; match = Match(bundleIds: app.match.bundleIds, appNames: app.match.appNames)
            } else { label = keyword; match = Match(aliases: [keyword], region: .anywhere) }
        }
        guard !label.isEmpty else { throw GenerationError.invalidCompiledRule("no keyword in input") }
        if kind == .person || kind == .topic {
            guard isUsableAlias(label) else { throw GenerationError.invalidCompiledRule("keyword is too short") }
        }
        let rule = Rule(id: UUID().uuidString, kind: kind, source: .user, input: input,
                        label: Label(zh: label, en: label), sentiment: sentiment, match: match,
                        highlight: kind == .person, variables: [:], createdAt: now)
        try RuleLoader.validate(rule)
        return rule
    }
}

public struct SpriteMark: Sendable {
    public var lineIndex: Int
    public var range: Range<String.Index>
    public var quote: String
    public var quip: Quip
}

public enum SpriteGenerator {
    public static let maxTokens = 450
    /// The grammar allows a little more (20 / 56) so the model finishes its sentence; longer lines are dropped, never cut.
    public static let spriteLimit = (zh: 18, en: 48)

    public static func generate(screen: SpriteScreen, snapshot: ContextSnapshot, app: String, title: String,
                                exclude: [String], persona: Persona, lang: Lang, k: Int,
                                generator: any TextGenerator,
                                onMark: @escaping @Sendable (SpriteMark) -> Void) async throws -> [SpriteMark] {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var stream = SpriteMarkStream()
            var marks: [SpriteMark] = []
            var error: (any Error)?
        }
        let state = State()
        let lines = screen.lines.map { snapshot.textLines[$0.lineIndex] }
        let prompt = GenerationPrompts.spriteMarks(app: app, title: title, screen: screen, exclude: exclude,
                                                   persona: persona, lang: lang, k: k)
        let receive: @Sendable (String) -> Bool = { partial in
            let accepted = state.lock.withLock { () -> [SpriteMark] in
                do {
                    var accepted: [SpriteMark] = []
                    for raw in try state.stream.feed(partial) {
                        guard screen.lines.indices.contains(raw.l), (2...32).contains(raw.q.count) else { continue }
                        var text = raw.t.trimmingCharacters(in: .whitespacesAndNewlines)
                        while let last = text.last, "，,、；;：:".contains(last) { text.removeLast() }
                        guard !text.isEmpty, text.count <= (lang == .zh ? spriteLimit.zh : spriteLimit.en),
                              !text.contains(where: QuipValidator.isEmoji), raw.e.count == 1,
                              QuipValidator.isEmoji(raw.e.first!),
                              text.range(of: "\\{[^{}]*\\}", options: .regularExpression) == nil,
                              let hit = SpriteLocator.locate(quote: raw.q, lineHint: raw.l, in: lines) else { continue }
                        let lineIndex = screen.lines[hit.lineIndex].lineIndex
                        let line = snapshot.textLines[lineIndex]
                        let rect = RuleMatcher.estimatedRect(for: line, range: hit.range)
                        guard !snapshot.sensitiveRects.contains(where: { $0.insetBy(dx: -60, dy: -60).intersects(rect) }),
                              !SpritePrompt.privacyRanges(in: line.text).contains(where: { $0.overlaps(hit.range) }),
                              !state.marks.contains(where: { $0.lineIndex == lineIndex && $0.range.overlaps(hit.range) }),
                              state.marks.count < k else { continue }
                        let mark = SpriteMark(lineIndex: lineIndex, range: hit.range, quote: String(line.text[hit.range]),
                                              quip: Quip(lang: lang, persona: persona, text: text, emoji: [raw.e]))
                        state.marks.append(mark)
                        accepted.append(mark)
                    }
                    return accepted
                } catch {
                    state.error = error
                    return []
                }
            }
            for mark in accepted { onMark(mark) }
            return state.lock.withLock { state.error == nil }
        }
        let json: String
        do {
            json = try await generator.generateJSON(system: prompt.system, prompt: prompt.user,
                schema: GenerationPrompts.spriteMarksSchema, maxTokens: maxTokens, partial: receive)
        } catch {
            if let decodingError = state.lock.withLock({ state.error }) { throw decodingError }
            throw error
        }
        struct Batch: Decodable { var marks: [RawMark] }
        _ = try JSONDecoder().decode(Batch.self, from: Data(json.utf8))
        _ = receive(json)
        if let error = state.lock.withLock({ state.error }) { throw error }
        return state.lock.withLock { state.marks }
    }
}
