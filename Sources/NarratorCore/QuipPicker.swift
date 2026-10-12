import Foundation

public struct QuipPicker: Sendable {
    private struct Key: Hashable, Sendable {
        var ruleID: String
        var lang: Lang
        var persona: Persona
    }
    private enum Pool: Hashable, Sendable { case normal, timed(When), generic }
    private struct QueueKey: Hashable, Sendable {
        var key: Key
        var pool: Pool
    }
    private var queues: [QueueKey: [Quip]] = [:]
    private var used: [Key: [String: Date]] = [:]

    public init() {}

    public static func render(_ text: String, rule: Rule, lang: Lang) -> String? {
        var values = rule.variables ?? [:]
        values["label"] = rule.label[lang]
        let regex = try! NSRegularExpression(pattern: "\\{([^{}]*)\\}")
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var rendered = text
        for match in matches.reversed() {
            let nameRange = Range(match.range(at: 1), in: text)!
            guard let value = values[String(text[nameRange])] else { return nil }
            rendered.replaceSubrange(Range(match.range, in: rendered)!, with: value)
        }
        return rendered
    }

    public mutating func pick<R: RandomNumberGenerator>(for rule: Rule, lang: Lang, persona: Persona,
        pack: QuipPack, disabledBuiltinIds: Set<String> = [], now: Date, calendar: Calendar = .current,
        using random: inout R) -> Quip? {
        let key = Key(ruleID: rule.id, lang: lang, persona: persona)
        let current = When.current(at: now, calendar: calendar)
        let own = rule.quips.filter { $0.lang == lang && $0.persona == persona }
        let timedRule = pack.rules.first { $0.id == "builtin.time.\(current.rawValue)" && $0.enabled && !disabledBuiltinIds.contains($0.id) }
        let timed = current == .any ? [] : own.filter { $0.when == current }
            + (timedRule?.quips.filter { $0.lang == lang && $0.persona == persona && $0.when == current } ?? [])
        let preferTimed = !timed.isEmpty && Double.random(in: 0..<1, using: &random) < 0.7
        let pool = preferTimed ? timed : own.filter { $0.when == .any }
        if let quip = take(pool, key: key, selection: preferTimed ? .timed(current) : .normal, rule: rule, now: now, using: &random) { return quip }
        let generic = (pack.generic[rule.sentiment.rawValue] ?? []).filter { $0.lang == lang && $0.persona == persona }
        return take(generic, key: key, selection: .generic, rule: rule, now: now, using: &random)
    }

    private mutating func take<R: RandomNumberGenerator>(_ pool: [Quip], key: Key, selection: Pool, rule: Rule, now: Date,
                                                        using random: inout R) -> Quip? {
        let available = pool.filter {
            Self.render($0.text, rule: rule, lang: key.lang) != nil
                && (used[key]?[$0.text].map { now.timeIntervalSince($0) >= 7200 } ?? true)
        }
        if available.isEmpty { return nil }
        let queueKey = QueueKey(key: key, pool: selection)
        var queue = queues[queueKey] ?? []
        queue.removeAll { !pool.contains($0) }
        if !queue.contains(where: { available.contains($0) }) { queue = pool.shuffled(using: &random) }
        let index = queue.firstIndex { available.contains($0) }!
        var quip = queue.remove(at: index)
        queues[queueKey] = queue
        used[key, default: [:]][quip.text] = now
        quip.text = Self.render(quip.text, rule: rule, lang: key.lang)!
        return quip
    }
}
