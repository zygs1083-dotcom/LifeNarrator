import AppKit
import NarratorCore

@MainActor
public final class NarratorEngine {
    private unowned let store: AppStore
    private let overlay: OverlayController
    private let quips: SpriteQuips
    private var sensor: ContextSensor!
    private var matcher = RuleMatcher(rules: [])
    private var scheduler = Scheduler()
    private var memory = SpriteMemory()
    private var picker = QuipPicker()
    private var pickerRules: [SpriteMemory.Key: Set<String>] = [:]
    private var random = SystemRandomNumberGenerator()
    private var generation = 0
    private var windowID: CGWindowID?
    private var chromeHeight: CGFloat = 52
    private var snapshot: ContextSnapshot?
    private var candidates: [Candidate] = []
    private var screenKey: UInt64?
    private var screenCount = 0
    private var shownTargets: [String: SpriteTarget] = [:]
    private var visits: [CGWindowID: Date] = [:]
    private var revisits: [CGWindowID: Date] = [:]
    private var revisitAllowed = false
    private var lastWindowFrameChange = Date.distantPast
    private var burst: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var modelBudget = SpriteModelBudget(perMinute: 4)
    private let debug = ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1"

    private struct ModelRequest {
        var snapshot: ContextSnapshot
        var lang: Lang
        var persona: String
        var generator: any TextGenerator
    }

    init(store: AppStore) throws {
        self.store = store
        quips = try SpriteQuips.loadBuiltin()
        overlay = OverlayController(style: store.settings.bubbleStyle)
        sensor = ContextSensor(onSnapshot: { [unowned self] in self.handle($0, $1) },
                               onWindowFrame: { [unowned self] in self.windowFrameChanged($0) },
                               onWindowChanged: { [unowned self] in self.windowChanged() },
                               onError: { [unowned self] in self.report($0) })
    }

    func start() throws {
        configure()
        try sensor.start()
    }

    func configure() {
        let settings = store.settings
        let levelChanged = overlay.liveliness != settings.liveliness
        matcher = RuleMatcher(rules: store.builtin.rules + store.rules, disabledBuiltinIds: settings.disabledBuiltinIds)
        overlay.style = settings.bubbleStyle
        overlay.liveliness = settings.liveliness
        scheduler.settings = .init(level: settings.liveliness)
        memory.level = settings.liveliness
        generation += 1
        burst?.cancel()
        if levelChanged || settings.paused { overlay.dismissAll() }
        guard var snapshot else { return }
        snapshot.capturedAt = Date()
        candidates = matcher.candidates(in: snapshot, now: snapshot.capturedAt, appChanged: true, hostChanged: true)
        if levelChanged { screenCount = 0 }
        runTick(.snapshot, switching: false)
    }

    private func handle(_ snapshot: ContextSnapshot, _ change: ContextChange) {
        generation += 1
        self.snapshot = snapshot
        let id = windowID ?? Self.lookupWindowID(pid: snapshot.pid, frame: snapshot.windowFrame)
        windowID = id
        chromeHeight = snapshot.contentFrame.minY - snapshot.windowFrame.minY
        let switching = change.appChanged || change.windowChanged
        // App/site rules also participate when switching windows inside the same app.
        candidates = matcher.candidates(in: snapshot, now: snapshot.capturedAt,
                                        appChanged: switching, hostChanged: switching || change.hostChanged)
        let all = SpriteScout.targets(in: snapshot, candidates: candidates, memory: SpriteMemory(),
                                      level: store.settings.liveliness)
        let key = stableHash("\(id)\n" + all.map { normalized($0.text) }.joined(separator: "\n"))
        if key != screenKey {
            screenKey = key
            screenCount = 0
            shownTargets = [:]
        } else {
            shownTargets = shownTargets.compactMapValues { previous in
                all.first { normalized($0.text) == normalized(previous.text) }
            }
        }
        if switching {
            burst?.cancel()
                let now = snapshot.capturedAt
            visits = visits.filter { now.timeIntervalSince($0.value) < 120 }
            revisits = revisits.filter { now.timeIntervalSince($0.value) < 30 }
            revisitAllowed = visits[id] != nil && revisits[id] == nil
            visits[id] = now
        }
        let generation = generation
        Task {
            do {
                _ = try await tick(.snapshot, switching: switching, generation: generation)
                guard generation == self.generation else { return }
                if switching {
                    scheduleLocalMarks()
                    if try quietReason(snapshot, now: Date()) == nil {
                        try enqueueModel(snapshot: snapshot)
                    }
                }
            } catch { report(error) }
        }
    }

    private func runTick(_ kind: SpriteTick, switching: Bool = false) {
        let generation = generation
        Task {
            do { _ = try await tick(kind, switching: switching, generation: generation) }
            catch { report(error) }
        }
    }

    private func quietReason(_ snapshot: ContextSnapshot, now: Date) throws -> String? {
        if store.settings.paused { return "paused" }
        if store.settings.blacklist.contains(snapshot.bundleId) { return "blacklisted" }
        if snapshot.pid == getpid() { return "own-window" }
        var current = snapshot
        current.secureFocused = try sensor.isSecureFocused()
        return SpriteTick.quietReason(in: current, typing: try sensor.isTyping(now: now),
                                      moving: now.timeIntervalSince(lastWindowFrameChange) < 0.5)
    }

    @discardableResult
    private func tick(_ kind: SpriteTick, switching: Bool, generation: Int) async throws -> Bool {
        guard let snapshot, let windowID, generation == self.generation else { return false }
        let now = Date()
        if let reason = try quietReason(snapshot, now: now) {
            log(snapshot, kind, targets: [], shown: false, reason: reason)
            return false
        }
        let level = store.settings.liveliness
        if level != .quiet && screenCount >= SpriteTick.screenLimit(level: level) {
            log(snapshot, kind, targets: [], shown: false, reason: "screen-limit")
            return false
        }
        let attempts = SpriteTick.attempts(in: snapshot, candidates: candidates, memory: memory,
                                           level: level, switching: switching, scheduler: scheduler,
                                           revisitAllowed: revisitAllowed, screen: SpritePrompt.screen(in: snapshot),
                                           screenKey: screenKey!, hasModel: false, requestAllowed: false, now: now)
        let targets = attempts.compactMap(\.target)
        for attempt in attempts {
            let target = attempt.target!
            let ruleID = attempt.ignoresRuleCooldown ? nil : target.candidate?.rule.id
            guard scheduler.canShow(ruleID: ruleID, now: now) else { continue }
            if let candidate = target.candidate, let configuration = store.settings.systemOne {
                let plan = SystemOneDecision.plan(snapshot: snapshot, candidates: [candidate], freeComments: false,
                                                  needsGeneration: false, now: now,
                                                  model: configuration.model.isEmpty ? "jev-latest" : configuration.model)
                var response: DecisionResponse?
                if !plan.request.questions.isEmpty {
                    let client = try SystemOneClient(baseURL: configuration.validatedURL(), key: KeychainStore.read(account: "systemOne"))
                    response = try await client.decide(plan.request)
                    guard generation == self.generation else { return false }
                }
                let outcome = try SystemOneDecision.evaluate(response, plan: plan, snapshot: snapshot)
                if !outcome.shouldShow { continue }
            }
            // Recheck silence and rate limits after a possible System One round trip.
            let showTime = Date()
            if let reason = try quietReason(snapshot, now: showTime) {
                log(snapshot, kind, targets: targets, shown: false, reason: reason)
                return false
            }
            guard scheduler.canShow(ruleID: ruleID, now: showTime) else { continue }
            var anchor: CGRect?
            if target.lineIndex >= 0 && snapshot.textSource != .none {
                anchor = try sensor.preciseRect(lineIndex: target.lineIndex, range: target.range)
                if anchor == nil {
                    anchor = RuleMatcher.estimatedRect(for: snapshot.textLines[target.lineIndex], range: target.range)
                }
            }
            let lang = store.settings.language.lang
            let persona = store.settings.persona.rawValue
            let key = SpriteMemory.Key(bundleId: snapshot.bundleId, text: target.text)
            let status = memory.status(key: key, now: showTime)
            let rule = target.candidate?.rule ?? quips.rule(for: target.category.rawValue, text: target.text,
                                                          app: snapshot.appName, title: snapshot.windowTitle ?? "", lang: lang)
            var nextPicker = picker
            var chosen: Quip?
            var source = target.category == .revisit ? "revisit" : target.category == .rule ? "rule" : "template"
            if target.category != .revisit, let status, status.isCached, status.quip.lang == lang, status.quip.persona.rawValue == persona,
               attempt.reason != "least-recent" {
                let cached = status.quip
                var modelRule = rule
                modelRule.quips = [cached]
                chosen = nextPicker.pick(for: modelRule, lang: lang, persona: .init(rawValue: persona)!, pack: .init(version: 1, rules: [], generic: [:]),
                                         now: showTime, using: &random)
                if chosen != nil { source = "model" }
            }
            if chosen == nil {
                var templateRule = rule
                if attempt.reason == "least-recent" {
                    templateRule.quips.removeAll { QuipPicker.render($0.text, rule: rule, lang: lang) == status?.quip.text }
                }
                chosen = nextPicker.pick(for: templateRule, lang: lang, persona: .init(rawValue: persona)!,
                    pack: target.category == .rule ? store.builtin : .init(version: 1, rules: [], generic: [:]),
                    disabledBuiltinIds: store.settings.disabledBuiltinIds, now: showTime, using: &random)
            }
            guard let chosen else { continue }
            let narrationID = UUID().uuidString
            let shown = overlay.show(Narration(id: narrationID, quipID: chosen.text, ruleID: rule.id,
                sequence: screenCount, text: chosen.text, emoji: chosen.emoji, language: lang.rawValue,
                persona: store.settings.persona, anchor: anchor, windowID: windowID,
                window: WindowGeometry(frame: snapshot.windowFrame, chromeHeight: chromeHeight)))
            guard shown else { continue }
            picker = nextPicker
            pickerRules[key, default: []].insert(rule.id)
            forget(memory.mark(key: key, quip: chosen, lineHint: target.lineIndex, now: showTime))
            scheduler.recordShown(ruleID: target.candidate?.rule.id, now: showTime)
            screenCount += 1
            shownTargets[narrationID] = target
            if target.category == .revisit {
                revisits[windowID] = showTime
                revisitAllowed = false
            }
            log(snapshot, kind, targets: targets, picked: target, source: source, shown: true, reason: attempt.reason)
            return true
        }
        log(snapshot, kind, targets: targets, shown: false, reason: attempts.isEmpty ? "no-targets" : "unavailable")
        return false
    }

    private func scheduleLocalMarks() {
        let delays = SpriteTick.localBurst(level: store.settings.liveliness)
        burst = Task {
            do {
                var previous = 0.0
                for delay in delays {
                    try await Task.sleep(for: .seconds(delay - previous))
                    try Task.checkCancellation()
                    previous = delay
                    _ = try await tick(.mark, switching: false, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch { report(error) }
        }
    }

    private func enqueueModel(snapshot: ContextSnapshot) throws {
        let screen = SpritePrompt.screen(in: snapshot)
        guard store.settings.liveliness != .quiet, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              !screen.lines.isEmpty, modelTask == nil, let generator = try store.textGenerator(),
              modelBudget.begin(now: Date()) else { return }
        let request = ModelRequest(snapshot: snapshot, lang: store.settings.language.lang,
                                   persona: store.settings.persona.rawValue, generator: generator)
        modelTask = Task {
            do {
                let result = try await SpriteGenerator.generate(screen: screen, snapshot: request.snapshot,
                    app: request.snapshot.appName, title: request.snapshot.windowTitle ?? "", exclude: [],
                    persona: .init(rawValue: request.persona)!, lang: request.lang,
                    k: store.settings.liveliness == .rowdy ? 4 : 3, generator: request.generator, onMark: { _ in })
                for mark in result {
                    forget(memory.cache(key: .init(bundleId: request.snapshot.bundleId, text: mark.quote),
                                        quip: mark.quip, lineHint: mark.lineIndex, now: Date()))
                }
            } catch { store.error = String(describing: error) }
            modelTask = nil
        }
    }

    /// Other apps' accessibility trees fail in app-specific ways; that read is dropped and the next change reads again.
    private func report(_ error: any Error) {
        if let failure = error as? AXFailure, failure.code != .apiDisabled {
            FileHandle.standardError.write(Data("[sprite] skipped read: \(error)\n".utf8))
        } else {
            store.error = String(describing: error)
        }
    }

    private func forget(_ key: SpriteMemory.Key?) {
        guard let key else { return }
        for id in pickerRules.removeValue(forKey: key) ?? [] { picker.forget(ruleID: id) }
    }

    private func windowFrameChanged(_ frame: CGRect) {
        lastWindowFrameChange = Date()
        guard let windowID else { return }
        if var snapshot {
            let dx = frame.minX - snapshot.windowFrame.minX, dy = frame.minY - snapshot.windowFrame.minY
            snapshot.windowFrame = frame
            snapshot.contentFrame = WindowGeometry(frame: frame, chromeHeight: chromeHeight).contentArea
            snapshot.textLines = snapshot.textLines.map { TextLine(text: $0.text, rect: $0.rect.offsetBy(dx: dx, dy: dy), role: $0.role) }
            snapshot.sensitiveRects = snapshot.sensitiveRects.map { $0.offsetBy(dx: dx, dy: dy) }
            self.snapshot = snapshot
        }
        overlay.windowFrameChanged(windowID, to: WindowGeometry(frame: frame, chromeHeight: chromeHeight))
    }

    private func windowChanged() {
        generation += 1
        burst?.cancel()
        overlay.dismissAll()
        shownTargets = [:]
        snapshot = nil
        screenKey = nil
        screenCount = 0
        windowID = nil
        lastWindowFrameChange = .distantPast
    }

    private func log(_ snapshot: ContextSnapshot, _ tick: SpriteTick, targets: [SpriteTarget],
                     picked: SpriteTarget? = nil, source: String = "-", shown: Bool, reason: String) {
        guard debug else { return }
        let targets = targets.map { "\($0.category.rawValue):\($0.score)@\($0.lineIndex)" }.joined(separator: ",")
        let pick = picked.map { "\($0.category.rawValue)@\($0.lineIndex)" } ?? "-"
        let color = shown ? overlay.lastShownColor.map(String.init) ?? "-" : "-"
        let elapsed = Int(Date().timeIntervalSince(snapshot.capturedAt) * 1000)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        FileHandle.standardError.write(Data("[sprite] \(snapshot.bundleId) tick=\(tick.rawValue) targets=[\(targets)] pick=\(pick) source=\(source) color=\(color) show=\(shown) reason=\(reason) \(elapsed)ms timestamp=\(timestamp)\n".utf8))
    }

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
