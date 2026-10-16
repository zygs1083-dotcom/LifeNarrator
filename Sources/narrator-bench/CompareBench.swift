import Foundation
import NarratorCore
import NarratorMac

private func emitCompare(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

private func percentile(_ values: [Double], _ fraction: Double) -> Any {
    guard !values.isEmpty else { return NSNull() }
    let sorted = values.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
}

func runCompare(_ arguments: CompareArguments) throws {
    if arguments.mtp { throw LlamaEngine.Failure.mtpUnavailable }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    for model in arguments.models {
        var baseline: Double?
        for speculative in arguments.draft == nil ? [false] : [false, true] {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--compare-worker", "--models", model]
            if speculative {
                process.arguments! += ["--draft", arguments.draft!, "--draft-tokens", String(arguments.draftTokens)]
            }
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            FileHandle.standardOutput.write(data)
            guard process.terminationStatus == 0 else { throw BenchError.measurement("compare worker exited \(process.terminationStatus): \(model)") }
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last!
            let summary = try JSONSerialization.jsonObject(with: Data(last.utf8)) as! [String: Any]
            let median = summary["total_p50_ms"] as! Double
            if speculative {
                try emitCompare(["type": "compare-speedup", "model": model,
                    "draft": arguments.draft!, "total_p50_speedup": baseline! / median])
            } else { baseline = median }
        }
    }
}

func runCompareWorker(_ arguments: CompareArguments) throws {
    guard arguments.models.count == 1 else { throw CompareArguments.Failure.usage }
    let path = arguments.models[0]
    let loadStart = ContinuousClock.now
    let engine = try LlamaEngine(modelPath: path, draftModelPath: arguments.draft,
                                 draftTokens: arguments.draftTokens, mtp: arguments.mtp)
    let loadSeconds = elapsed(loadStart)
    var prefill: [Double] = []
    var first: [Double] = []
    var totals: [Double] = []
    var totalTokens = 0
    var decodeSeconds = 0.0
    var proposed = 0
    var accepted = 0
    var markCount = 0
    var locatedCount = 0
    var repeatDrops = 0
    var said = SaidHistory()
    var texts: [(String, Lang)] = []
    let mode = arguments.draft == nil ? "baseline" : "draft"
    var markdown = "# \(URL(fileURLWithPath: path).lastPathComponent) — \(mode)\n\n"
    markdown += "Model: `\(path)`\n\nDraft: `\(arguments.draft ?? "off")`; k=5; persona=sharp; runs/screen=3.\n\n"
    for sample in spriteCases {
        let snapshot = sample.snapshot
        let screen = SpritePrompt.screen(in: snapshot)
        let lines = screen.lines.map { snapshot.textLines[$0.lineIndex] }
        let prompt = GenerationPrompts.spriteMarks(app: snapshot.appName, title: sample.id,
            screen: screen, exclude: [], persona: .sharp, lang: sample.lang, k: 5)
        let chat = try engine.chat(system: prompt.system, user: prompt.user)
        markdown += "## \(sample.id)\n\nScreen (zero-based prompt line numbers):\n\n"
        markdown += screen.lines.enumerated().map { "\($0.offset). \(lines[$0.offset].text)" }.joined(separator: "\n\n") + "\n\n"
        for run in 1...3 {
            var stream = SpriteMarkStream()
            var firstSeconds: Double?
            var streamError: (any Error)?
            let start = ContinuousClock.now
            let output = try engine.generate(prompt: chat.prompt, grammar: LlamaGrammar.spriteMarks,
                maxTokens: SpriteGenerator.maxTokens, cachePrefix: chat.prefix, seed: UInt32(20261016 + run)) { partial in
                do {
                    if !(try stream.feed(partial)).isEmpty && firstSeconds == nil { firstSeconds = elapsed(start) }
                } catch { streamError = error; return false }
                return true
            }
            if let streamError { throw streamError }
            let total = elapsed(start)
            struct Batch: Decodable { let marks: [RawMark] }
            let marks = try JSONDecoder().decode(Batch.self, from: Data(output.utf8)).marks
            markdown += "### Run \(run)\n\n"
            var items: [[String: Any]] = []
            for mark in marks {
                let hit = SpriteLocator.locate(quote: mark.q, lineHint: mark.l, in: lines)
                markCount += 1
                if hit != nil { locatedCount += 1 }
                let repeated = said.isRepeat(mark.t, now: snapshot.capturedAt)
                if repeated { repeatDrops += 1 }
                else {
                    said.record(mark.t, now: snapshot.capturedAt)
                    texts.append((mark.t, sample.lang))
                }
                items.append(["l": mark.l, "q": mark.q, "t": mark.t, "e": mark.e,
                              "located": hit != nil, "repeat_drop": repeated])
                markdown += "- \(mark.e) \(mark.t)\n  - q: \(mark.q)\n  - requested line: \(mark.l); located line: \(hit.map { String($0.lineIndex) } ?? "none"); repeat drop: \(repeated)\n"
            }
            if marks.isEmpty { markdown += "(empty marks)\n" }
            markdown += "\nRaw JSON:\n\n    \(output.replacingOccurrences(of: "\n", with: "\n    "))\n\n"
            prefill.append(engine.lastPrefillSeconds * 1000)
            if let firstSeconds { first.append(firstSeconds * 1000) }
            totals.append(total * 1000)
            totalTokens += engine.generatedTokens
            decodeSeconds += total - engine.lastPrefillSeconds
            proposed += engine.proposedTokens
            accepted += engine.acceptedTokens
            try emitCompare(["type": "compare-run", "model": path, "mode": mode, "case": sample.id, "run": run,
                "prefill_ms": engine.lastPrefillSeconds * 1000, "prefix_cached": engine.lastPrefixCached,
                "first_ms": firstSeconds.map { $0 * 1000 as Any } ?? NSNull(), "total_ms": total * 1000,
                "generated_tokens": engine.generatedTokens, "marks": items,
                "proposed_tokens": engine.proposedTokens, "accepted_tokens": engine.acceptedTokens])
        }
    }
    var bigrams: [String] = []
    var openings: [String: Int] = [:]
    for (text, lang) in texts {
        let normalized = SaidHistory.normalizedText(text)
        let characters = Array(normalized)
        if characters.count > 1 {
            bigrams += (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
        }
        let opening = lang == .zh ? String(characters.prefix(2))
            : SaidHistory.normalizedText(String(text.split(whereSeparator: \.isWhitespace).first ?? ""))
        openings[opening, default: 0] += 1
    }
    let directory = URL(fileURLWithPath: ".dev-data/model-bench")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let report = directory.appendingPathComponent("\(URL(fileURLWithPath: path).lastPathComponent)-\(stableHash(path))-\(mode).md")
    try markdown.write(to: report, atomically: true, encoding: .utf8)
    try emitCompare([
        "type": "compare-summary", "model": path, "mode": mode, "draft": arguments.draft as Any? ?? NSNull(),
        "runs": totals.count, "k": 5, "persona": "sharp", "load_ms": loadSeconds * 1000,
        "prefill_p50_ms": percentile(prefill, 0.5), "prefill_p90_ms": percentile(prefill, 0.9),
        "first_p50_ms": percentile(first, 0.5), "first_p90_ms": percentile(first, 0.9), "runs_with_first_mark": first.count,
        "total_p50_ms": percentile(totals, 0.5), "total_p90_ms": percentile(totals, 0.9),
        "tokens_per_second": Double(totalTokens) / decodeSeconds, "generated_tokens": totalTokens,
        "marks": markCount, "located": locatedCount,
        "location_ratio": markCount == 0 ? NSNull() : Double(locatedCount) / Double(markCount) as Any,
        "repeat_drops": repeatDrops, "distinct_2": bigrams.isEmpty ? 0 : Double(Set(bigrams).count) / Double(bigrams.count),
        "opening_concentration": texts.isEmpty ? 0 : Double(openings.values.max()!) / Double(texts.count),
        "proposed_tokens": proposed, "accepted_tokens": accepted,
        "acceptance_rate": proposed == 0 ? NSNull() : Double(accepted) / Double(proposed) as Any,
        "peak_rss_bytes": try peakRSS(), "markdown": report.path,
        "metric_notes": "Isolated process per model/mode. Load includes draft, excluded from request latency. Prefill includes prefix snapshots and draft prompt. First is first raw complete mark (null for empty runs). tok/s excludes prefill, includes speculation overhead. Diversity and repeat drops use all raw t with SaidHistory across 18 runs; first/marks/location precede production validation. Bigrams are normalized characters; opening is first 2 zh characters / first en word. Percentiles use nearest rank. Speedup is baseline/draft p50 batch wall time; no speedup is assumed.",
    ])
}
