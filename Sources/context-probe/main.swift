import AppKit
import Foundation
import NarratorCore
import NarratorMac

struct ProbeCandidate: Encodable {
    let ruleID: String
    let kind: RuleKind
    let matchedText: String?
    let lineIndex: Int?
    let matchRange: NSRange?
    let highlightRect: CGRect?
}

struct ProbeOutput: Encodable {
    let snapshot: ContextSnapshot
    let change: ContextChange
    let reason: ContextChange.Reason
    let candidates: [ProbeCandidate]
}

func fail(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("context-probe failed: \(error)\n".utf8))
    exit(1)
}

@MainActor
func run() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard ContextPermissions.isGranted(.accessibility) || ContextPermissions.request(.accessibility) else {
        FileHandle.standardError.write(Data("Grant Accessibility access to context-probe, then run it again.\n".utf8))
        exit(1)
    }
    if !ContextPermissions.isGranted(.screenCapture) { ContextPermissions.request(.screenCapture) }
    let pack = try RuleLoader.loadBuiltin()
    let person = Rule(id: "probe.person.zhang-san", kind: .person, source: .user,
                      label: Label(zh: "张三", en: "Zhang San"), sentiment: .neutral,
                      match: Match(aliases: ["张三"], region: .header), highlight: true)
    let matcher = RuleMatcher(rules: pack.rules + [person])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let sensor = ContextSensor(onSnapshot: { _, _ in }, onWindowFrame: { _ in }, onError: { fail($0) })
    sensor.onSnapshot = { [weak sensor] snapshot, change in
        do {
            let candidates = try matcher.candidates(in: snapshot, now: snapshot.capturedAt,
                                                     appChanged: change.appChanged, hostChanged: change.hostChanged).map { candidate in
                var index = candidate.lineIndex
                var range = candidate.matchRange
                if candidate.rule.highlight && index == nil,
                   let hit = RuleMatcher.matchingLines(for: candidate.rule, in: snapshot).first {
                    index = hit.index
                    range = hit.range
                }
                var highlight: CGRect?
                if candidate.rule.highlight, let index, let range {
                    highlight = try sensor!.preciseRect(lineIndex: index, range: range)
                        ?? RuleMatcher.estimatedRect(for: snapshot.textLines[index], range: range)
                }
                let nsRange = index.flatMap { index in range.map { NSRange($0, in: snapshot.textLines[index].text) } }
                return ProbeCandidate(ruleID: candidate.rule.id, kind: candidate.rule.kind,
                                      matchedText: candidate.matchedText, lineIndex: index,
                                      matchRange: nsRange, highlightRect: highlight)
            }
            let output = ProbeOutput(snapshot: snapshot, change: change, reason: change.reason, candidates: candidates)
            FileHandle.standardOutput.write(try encoder.encode(output) + Data([10]))
        } catch { fail(error) }
    }
    try sensor.start()
    withExtendedLifetime(sensor) { app.run() }
    sensor.stop()
}

do { try run() } catch { fail(error) }
