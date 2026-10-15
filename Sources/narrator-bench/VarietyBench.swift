import Foundation
import NarratorCore
import NarratorMac

private final class VarietyResults: @unchecked Sendable {
    private let lock = NSLock()
    private var said = SaidHistory()
    private var accepted: [(text: String, lang: Lang)] = []
    private var rejected = 0
    var recent: [String] { lock.withLock { said.recent(8) } }

    func isRepeat(_ text: String, lang: Lang) -> Bool {
        lock.withLock {
            let now = Date()
            if said.isRepeat(text, now: now) {
                rejected += 1
                return true
            }
            said.record(text, now: now)
            accepted.append((text, lang))
            return false
        }
    }

    func summary(requests: Int) throws {
        let result = lock.withLock { (accepted, rejected) }
        let items = result.0
        var bigrams: [String] = []
        var openings: [String: Int] = [:]
        var pairs = 0
        let now = Date()
        for (index, item) in items.enumerated() {
            let characters = Array(SaidHistory.normalizedText(item.text))
            if characters.count >= 2 {
                bigrams += (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
            }
            let opening = item.lang == .zh ? String(characters.prefix(2))
                : SaidHistory.normalizedText(String(item.text.split(whereSeparator: \.isWhitespace).first!))
            openings[opening, default: 0] += 1
            var history = SaidHistory()
            history.record(item.text, now: now)
            pairs += items.dropFirst(index + 1).filter { history.isRepeat($0.text, now: now) }.count
        }
        let summary: [String: Any] = [
            "requests": requests, "accepted_marks": items.count, "repeat_drops": result.1,
            "distinct_2": bigrams.isEmpty ? 0 : Double(Set(bigrams).count) / Double(bigrams.count),
            "opening_concentration": items.isEmpty ? 0 : Double(openings.values.max()!) / Double(items.count),
            "similar_pairs": pairs,
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}

func runVariety(rounds: Int) async throws {
    let directory = try AppDataDirectory()
    let generator = LlamaGenerator(modelPath: directory.models.appendingPathComponent(ModelCatalog.models[0].filename).path)
    let results = VarietyResults()
    for _ in 0..<rounds {
        for sample in spriteCases {
            let snapshot = sample.snapshot
            _ = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
                app: snapshot.appName, title: sample.id, exclude: [], persona: .sharp, lang: sample.lang, k: 4,
                recent: results.recent, generator: generator,
                isRepeat: { results.isRepeat($0, lang: sample.lang) }, onMark: { _ in })
        }
    }
    try results.summary(requests: rounds * spriteCases.count)
}
