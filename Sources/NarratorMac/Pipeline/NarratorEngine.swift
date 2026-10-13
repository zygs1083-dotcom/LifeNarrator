import AppKit
import NarratorCore

/// Snapshot → rule prefilter → edge/typing/rate filters → optional System One → quip → overlay.
@MainActor
public final class NarratorEngine {
    private unowned let store: AppStore
    private let overlay: OverlayController
    private var sensor: ContextSensor!
    private var matcher = RuleMatcher(rules: [])
    private var scheduler = Scheduler()
    private var picker = QuipPicker()
    private var random = SystemRandomNumberGenerator()
    private var generation = 0
    private var windowID: CGWindowID?
    private var chromeHeight: CGFloat = 52
    private var sequences: [String: Int] = [:]
    private let debug = ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1"

    init(store: AppStore) {
        self.store = store
        overlay = OverlayController(style: store.settings.bubbleStyle)
        sensor = ContextSensor(onSnapshot: { [unowned self] in self.handle($0, $1) },
                               onWindowFrame: { [unowned self] in self.windowFrameChanged($0) },
                               onWindowChanged: { [unowned self] in self.windowChanged() },
                               onError: { [unowned self] in self.store.error = String(describing: $0) })
    }

    func start() throws {
        configure()
        try sensor.start()
    }

    /// Re-reads settings and rules; called by the store whenever either changes.
    func configure() {
        let settings = store.settings
        matcher = RuleMatcher(rules: store.builtin.rules + store.rules, disabledBuiltinIds: settings.disabledBuiltinIds)
        overlay.style = settings.bubbleStyle
        scheduler.settings.ruleCooldown = settings.ruleCooldown
        scheduler.settings.globalPerMinute = settings.globalPerMinute
        scheduler.settings.minGap = settings.minGap
    }

    private func handle(_ snapshot: ContextSnapshot, _ change: ContextChange) {
        generation += 1
        let id = windowID ?? Self.lookupWindowID(pid: snapshot.pid, frame: snapshot.windowFrame)
        windowID = id
        chromeHeight = snapshot.contentFrame.minY - snapshot.windowFrame.minY
        let settings = store.settings
        if settings.paused { return log(snapshot, [], shown: false, "paused") }
        if settings.blacklist.contains(snapshot.bundleId) { return log(snapshot, [], shown: false, "blacklisted") }
        let now = snapshot.capturedAt
        do {
            var candidates = matcher.candidates(in: snapshot, now: now, appChanged: change.appChanged, hostChanged: change.hostChanged)
            var typing = false
            if try sensor.isTyping(now: now) {
                typing = true
                candidates.removeAll { $0.rule.kind == .person || $0.rule.kind == .topic }
            }
            candidates = scheduler.triggers(from: candidates)
            guard !candidates.isEmpty else { return log(snapshot, [], shown: false, typing ? "typing, no candidates" : "no candidates") }
            let generation = self.generation
            Task {
                do { try await decide(snapshot, candidates, now: now, generation: generation, windowID: id) }
                catch { store.error = String(describing: error) }
            }
        } catch { store.error = String(describing: error) }
    }

    private func decide(_ snapshot: ContextSnapshot, _ candidates: [Candidate], now: Date, generation: Int,
                        windowID: CGWindowID) async throws {
        var candidate = candidates[0]
        var highlightIndex = candidate.rule.highlight
            ? candidate.lineIndex ?? RuleMatcher.matchingLines(for: candidate.rule, in: snapshot).first?.index : nil
        if let configuration = store.settings.systemOne {
            let plan = SystemOneDecision.plan(snapshot: snapshot, candidates: candidates, freeComments: false, needsGeneration: false,
                                              now: now, model: configuration.model.isEmpty ? "jev-latest" : configuration.model)
            var response: DecisionResponse?
            if !plan.request.questions.isEmpty {
                let client = try SystemOneClient(baseURL: configuration.validatedURL(), key: KeychainStore.read(account: "systemOne"))
                response = try await client.decide(plan.request)
                guard generation == self.generation else { return log(snapshot, candidates, shown: false, "screen changed during System One") }
            }
            let outcome = try SystemOneDecision.evaluate(response, plan: plan, snapshot: snapshot)
            guard outcome.shouldShow, let chosen = outcome.candidate else { return log(snapshot, candidates, shown: false, "System One declined") }
            candidate = chosen
            highlightIndex = outcome.highlightLineIndex
        }
        let rule = candidate.rule
        guard scheduler.canShow(ruleID: rule.id, now: now) else { return log(snapshot, candidates, shown: false, "rate limited \(rule.id)") }
        let lang = store.settings.language.lang
        let persona = store.settings.persona
        guard let quip = picker.pick(for: rule, lang: lang, persona: .init(rawValue: persona.rawValue)!, pack: store.builtin,
                                     disabledBuiltinIds: store.settings.disabledBuiltinIds, now: now, using: &random) else {
            return log(snapshot, candidates, shown: false, "no quip for \(rule.id)")
        }
        var anchor: CGRect?
        if let index = highlightIndex {
            let range = index == candidate.lineIndex ? candidate.matchRange!
                : RuleMatcher.matchingLines(for: rule, in: snapshot).first { $0.index == index }!.range
            anchor = try sensor.preciseRect(lineIndex: index, range: range)
                ?? RuleMatcher.estimatedRect(for: snapshot.textLines[index], range: range)
        }
        scheduler.recordShown(ruleID: rule.id, now: now)
        let sequence = sequences[rule.id, default: 0]
        sequences[rule.id] = sequence + 1
        overlay.show(Narration(id: UUID().uuidString, quipID: quip.text, ruleID: rule.id, sequence: sequence, text: quip.text,
                               emoji: quip.emoji, language: lang.rawValue, persona: persona, anchor: anchor, windowID: windowID,
                               window: WindowGeometry(frame: snapshot.windowFrame, chromeHeight: chromeHeight)))
        log(snapshot, candidates, shown: true, "rule \(rule.id)\(anchor == nil ? "" : " anchored")")
    }

    private func windowFrameChanged(_ frame: CGRect) {
        guard let windowID else { return }
        overlay.windowFrameChanged(windowID, to: WindowGeometry(frame: frame, chromeHeight: chromeHeight))
    }

    private func windowChanged() {
        overlay.dismissAll()
        scheduler.clearPresence()
        windowID = nil
    }

    private func log(_ snapshot: ContextSnapshot, _ candidates: [Candidate], shown: Bool, _ reason: String) {
        guard debug else { return }
        let ids = candidates.map(\.rule.id).joined(separator: ",")
        FileHandle.standardError.write(Data("[narrator] \(snapshot.bundleId) candidates=[\(ids)] show=\(shown) \(reason)\n".utf8))
    }

    /// The on-screen window of `pid` that best matches `frame` (intersection over union, so a larger window
    /// behind it does not win); AX gives no window number directly.
    private static func lookupWindowID(pid: pid_t, frame: CGRect) -> CGWindowID {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
        func overlap(_ info: [String: Any]) -> CGFloat {
            let bounds = CGRect(dictionaryRepresentation: info[kCGWindowBounds as String] as! CFDictionary)!
            let shared = bounds.intersection(frame)
            let union = bounds.width * bounds.height + frame.width * frame.height - shared.width * shared.height
            return shared.width * shared.height / union
        }
        let own = windows.filter { $0[kCGWindowOwnerPID as String] as! pid_t == pid }
        return own.max { overlap($0) < overlap($1) }.map { $0[kCGWindowNumber as String] as! CGWindowID } ?? kCGNullWindowID
    }
}
