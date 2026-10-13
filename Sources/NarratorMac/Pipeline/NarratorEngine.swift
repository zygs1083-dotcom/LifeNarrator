import AppKit
import NarratorCore

/// Shared with the model's serial executor; no screen text is retained in the metrics.
private final class SpriteRequestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = SpriteMarkStream()
    private var marks = 0
    private var located = 0
    private var first: Date?
    private var timedOut = false

    func feed(_ text: String) throws -> [RawMark] {
        try lock.withLock {
            let raw = try parser.feed(text)
            marks += raw.count
            return raw
        }
    }

    func accepted() {
        lock.withLock {
            located += 1
            if first == nil { first = Date() }
        }
    }

    func timeout() -> Bool {
        lock.withLock {
            guard first == nil else { return false }
            timedOut = true
            return true
        }
    }

    var metrics: (marks: Int, located: Int, first: Date?, timedOut: Bool) {
        lock.withLock { (marks, located, first, timedOut) }
    }
}

private struct SpriteRequestGenerator: TextGenerator {
    let base: any TextGenerator
    let progress: SpriteRequestProgress
    let lines: [TextLine]
    let lineIndices: [Int]
    let onMissing: @Sendable (Int) -> Void

    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens, partial: { _ in true })
    }

    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                      partial: @escaping @Sendable (String) -> Bool) async throws -> String {
        try Task.checkCancellation()
        let json = try await base.generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens) {
            // SpriteGenerator owns parsing errors; this parser only counts completed raw marks.
            do { inspect(try progress.feed($0)) } catch { return partial($0) }
            return !Task.isCancelled && partial($0)
        }
        try Task.checkCancellation()
        inspect(try progress.feed(json))
        return json
    }

    private func inspect(_ raw: [RawMark]) {
        for mark in raw where lines.indices.contains(mark.l) {
            if SpriteLocator.locate(quote: mark.q, lineHint: mark.l, in: lines) == nil {
                onMissing(lineIndices[mark.l])
            }
        }
    }
}

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
    private var shownPlaces: [(quote: String, rect: CGRect)] = []
    private var queuedPlaces: [UUID: (quote: String, rect: CGRect?)] = [:]
    private var visits: [CGWindowID: Date] = [:]
    private var revisits: [CGWindowID: Date] = [:]
    private var revisitAllowed = false
    private var lastShownAt: Date?
    private var lastWindowFrameChange = Date.distantPast
    private var releases: [UUID: Task<Void, Never>] = [:]
    private var followup: Task<Void, Never>?
    private var ocr: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var requestPending = false
    private var emptyScreens: Set<UInt64> = []
    private var windowRequests: [CGWindowID: Date] = [:]
    private var modelBudget = SpriteModelBudget(perMinute: 4)
    private let debug = ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1"

    private struct ModelRequest {
        let snapshot: ContextSnapshot
        let screen: SpriteScreen
        let key: UInt64
        let windowID: CGWindowID
        let generation: Int
        let lang: Lang
        let persona: String
        let level: Liveliness
        let exclude: [String]
        let generator: any TextGenerator
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
        matcher = makeMatcher()
        overlay.style = settings.bubbleStyle
        overlay.liveliness = settings.liveliness
        scheduler.settings = .init(level: settings.liveliness)
        memory.level = settings.liveliness
        cancelScreen()
        if modelTask != nil { requestPending = true }
        if levelChanged {
            modelBudget = SpriteModelBudget(perMinute: settings.liveliness == .rowdy ? 6 : 4)
            screenCount = 0
        }
        if levelChanged || settings.paused {
            overlay.dismissAll()
            shownPlaces = []
        }
        guard let snapshot else { return }
        candidates = matcher.candidates(in: snapshot, now: Date(), appChanged: true, hostChanged: true)
        runTick(.snapshot, switching: false)
    }

    private func makeMatcher() -> RuleMatcher {
        let settings = store.settings
        let available: Bool
        switch settings.provider {
        case .none: available = false
        case .builtin: if case .ready = store.downloader.state { available = true } else { available = false }
        case .openAICompatible: available = true
        }
        return RuleMatcher(userRules: store.rules, builtinRules: store.builtin.rules,
            hasModel: available && settings.liveliness != .quiet && !ProcessInfo.processInfo.isLowPowerModeEnabled,
            disabledBuiltinIds: settings.disabledBuiltinIds)
    }

    private func positions(excluding id: UUID, snapshot: ContextSnapshot) -> [SpriteLocator.Position] {
        let shown = shownPlaces.map { entry in
            SpriteLocator.Position(lineIndex: SpriteLocator.locate(quote: entry.quote, lineHint: -1, in: snapshot.textLines)?.lineIndex ?? -1,
                rect: entry.rect.offsetBy(dx: snapshot.windowFrame.minX, dy: snapshot.windowFrame.minY))
        }
        let queued = queuedPlaces.filter { $0.key != id }.values.compactMap { entry -> SpriteLocator.Position? in
            guard let rect = entry.rect else { return nil }
            if let hit = SpriteLocator.locate(quote: entry.quote, lineHint: -1, in: snapshot.textLines) {
                return .init(lineIndex: hit.lineIndex,
                    rect: RuleMatcher.estimatedRect(for: snapshot.textLines[hit.lineIndex], range: hit.range))
            }
            return .init(lineIndex: -1, rect: rect.offsetBy(dx: snapshot.windowFrame.minX, dy: snapshot.windowFrame.minY))
        }
        return shown + queued
    }

    private func reserve(mark: SpriteMark) -> UUID? {
        guard let snapshot else { return nil }
        let screen = SpritePrompt.screen(in: snapshot)
        let lines = screen.lines.map { snapshot.textLines[$0.lineIndex] }
        let hint = screen.lines.firstIndex { $0.lineIndex == mark.lineIndex } ?? -1
        guard let hit = SpriteLocator.locate(quote: mark.quote, lineHint: hint, in: lines) else { return nil }
        return reserve(quote: mark.quote, lineIndex: screen.lines[hit.lineIndex].lineIndex)
    }

    private func reserve(quote: String, lineIndex: Int) -> UUID? {
        let snapshot = snapshot!
        guard memory.status(key: .init(bundleId: snapshot.bundleId, text: quote), now: Date())?.isMarked != true,
              !queuedPlaces.values.contains(where: { normalized($0.quote) == normalized(quote) }) else { return nil }
        let id = UUID()
        let hit = lineIndex >= 0 ? SpriteLocator.locate(quote: quote, lineHint: lineIndex, in: snapshot.textLines) : nil
        if lineIndex >= 0 && hit == nil { return nil }
        let lineIndex = hit?.lineIndex ?? -1
        let rect = hit.map { RuleMatcher.estimatedRect(for: snapshot.textLines[$0.lineIndex], range: $0.range) }
        if let rect, SpriteLocator.conflicts(.init(lineIndex: lineIndex, rect: rect),
            with: positions(excluding: id, snapshot: snapshot)) { return nil }
        queuedPlaces[id] = (quote, rect?.offsetBy(dx: -snapshot.windowFrame.minX, dy: -snapshot.windowFrame.minY))
        return id
    }

    private func waitForTyping(generation: Int, source: String) async throws {
        var logged = false
        while true {
            while try sensor.isTyping(now: Date()) {
                try Task.checkCancellation()
                if generation != self.generation { throw CancellationError() }
                if !logged, let snapshot {
                    log(snapshot, .mark, source: source, shown: false, reason: "deferred-typing")
                    logged = true
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            try await waitForGap(generation: generation)
            if try !sensor.isTyping(now: Date()) { return }
        }
    }

    private func releaseTargets(_ attempts: [SpriteTick.Attempt], tick: SpriteTick, generation: Int) {
        guard !attempts.isEmpty else { return }
        let id = UUID()
        releases[id] = Task {
            defer { releases.removeValue(forKey: id) }
            do {
                for attempt in attempts {
                    if try await showTarget(attempt, tick: tick, generation: generation) { break }
                }
            } catch is CancellationError { return }
            catch { report(error) }
        }
    }

    private func handle(_ snapshot: ContextSnapshot, _ change: ContextChange) {
        let id = windowID ?? Self.lookupWindowID(pid: snapshot.pid, frame: snapshot.windowFrame)
        let screen = SpritePrompt.screen(in: snapshot)
        let key = stableHash("\(id)\n" + screen.lines.map { normalized($0.text) }.joined(separator: "\n"))
        let switching = SpriteTick.resetsWindow(appChanged: change.appChanged, windowChanged: change.windowChanged)
        let changed = key != screenKey
        self.snapshot = snapshot
        windowID = id
        chromeHeight = snapshot.contentFrame.minY - snapshot.windowFrame.minY
        matcher = makeMatcher()
        candidates = matcher.candidates(in: snapshot, now: snapshot.capturedAt,
                                        appChanged: switching, hostChanged: switching || change.hostChanged)
        screenKey = key
        if switching {
            cancelScreen()
            overlay.dismissAll()
            screenCount = 0
            shownPlaces = []
        }
        if switching {
            let now = snapshot.capturedAt
            visits = visits.filter { now.timeIntervalSince($0.value) < 120 }
            revisits = revisits.filter { now.timeIntervalSince($0.value) < 600 }
            revisitAllowed = SpriteTick.revisitAllowed(lastVisit: visits[id], lastRevisit: revisits[id], now: now)
            visits[id] = now
        }
        if modelTask != nil && (changed || switching) { requestPending = true }
        else if changed && !switching && Date().timeIntervalSince(windowRequests[id] ?? .distantPast)
            < SpriteTick.windowRequestInterval(level: store.settings.liveliness) { scheduleLatestRequest() }
        // Identical AX notifications must not restart releases or create another request.
        if changed || switching { runTick(.snapshot, switching: switching) }
    }

    private func runTick(_ kind: SpriteTick, switching: Bool = false) {
        let generation = generation
        Task {
            do { try await tick(kind, switching: switching, generation: generation) }
            catch is CancellationError { return }
            catch { report(error) }
        }
    }

    private func quietReason(_ snapshot: ContextSnapshot, now: Date) throws -> String? {
        if store.settings.paused { return "paused" }
        if store.settings.blacklist.contains(snapshot.bundleId) { return "blacklisted" }
        if snapshot.pid == getpid() { return "own-window" }
        var current = snapshot
        current.secureFocused = try sensor.isSecureFocused()
        return SpriteTick.quietReason(in: current, typing: false,
                                      moving: now.timeIntervalSince(lastWindowFrameChange) < 0.5)
    }

    private func requestAllowed(now: Date) -> Bool {
        guard modelTask == nil, let windowID, let screenKey, !emptyScreens.contains(screenKey) else { return false }
        var budget = modelBudget
        return now.timeIntervalSince(windowRequests[windowID] ?? .distantPast) >= SpriteTick.windowRequestInterval(level: store.settings.liveliness)
            && budget.begin(now: now)
    }

    private func tick(_ kind: SpriteTick, switching: Bool, generation: Int) async throws {
        guard let snapshot, let screenKey, generation == self.generation else { return }
        let now = Date()
        if let reason = try quietReason(snapshot, now: now) {
            log(snapshot, kind, shown: false, reason: reason)
            return
        }
        let level = store.settings.liveliness
        let generator = level != .quiet && !ProcessInfo.processInfo.isLowPowerModeEnabled ? try store.textGenerator() : nil
        let screen = SpritePrompt.screen(in: snapshot)
        let attempts = SpriteTick.attempts(in: snapshot, candidates: candidates, memory: memory,
            level: level, switching: switching, scheduler: scheduler, revisitAllowed: revisitAllowed,
            screen: screen, screenKey: screenKey, hasModel: generator != nil,
            requestAllowed: requestAllowed(now: now), now: now)
        releaseTargets(attempts.filter { $0.target?.category == .rule }, tick: kind, generation: generation)
        guard generation == self.generation else { return }
        let marks = attempts.filter { $0.mark != nil }
        if !marks.isEmpty {
            replay(marks, generation: generation)
        } else if attempts.contains(where: { $0.reason == "request" }), let generator {
            log(snapshot, kind, source: "model", shown: false, reason: "waiting-model")
            enqueueModel(ModelRequest(snapshot: snapshot, screen: screen, key: screenKey, windowID: windowID!,
                generation: generation, lang: store.settings.language.lang,
                persona: store.settings.persona.rawValue, level: level,
                exclude: memory.shownQuotes(bundleId: snapshot.bundleId, now: now), generator: generator))
        } else {
            let local = attempts.filter { $0.target != nil && $0.target?.category != .rule }
            releaseTargets(local, tick: kind, generation: generation)
            if generator == nil && kind == .snapshot { scheduleLocalMarks(generation: generation) }
            if local.isEmpty { log(snapshot, kind, shown: false, reason: attempts.isEmpty ? "no-targets" : "unavailable") }
        }
    }

    private func canShow(_ snapshot: ContextSnapshot, ruleID: String?, now: Date) throws -> Bool {
        if let reason = try quietReason(snapshot, now: now) {
            log(snapshot, .mark, shown: false, reason: reason)
            return false
        }
        let level = store.settings.liveliness
        if level != .quiet && screenCount >= SpriteTick.screenLimit(level: level) {
            log(snapshot, .mark, shown: false, reason: "screen-limit")
            return false
        }
        return scheduler.canShow(ruleID: ruleID, now: now)
    }

    @discardableResult
    private func showTarget(_ attempt: SpriteTick.Attempt, tick: SpriteTick, generation: Int) async throws -> Bool {
        guard let snapshot, generation == self.generation else { return false }
        let target = attempt.target!
        let ruleID = attempt.ignoresRuleCooldown ? nil : target.candidate?.rule.id
        guard try canShow(snapshot, ruleID: ruleID, now: Date()) else { return false }
        if let candidate = target.candidate, let configuration = store.settings.systemOne {
            let plan = SystemOneDecision.plan(snapshot: snapshot, candidates: [candidate], freeComments: false,
                needsGeneration: false, now: Date(), model: configuration.model.isEmpty ? "jev-latest" : configuration.model)
            var response: DecisionResponse?
            if !plan.request.questions.isEmpty {
                let client = try SystemOneClient(baseURL: configuration.validatedURL(), key: KeychainStore.read(account: "systemOne"))
                response = try await client.decide(plan.request)
                guard generation == self.generation else { return false }
            }
            if try !SystemOneDecision.evaluate(response, plan: plan, snapshot: snapshot).shouldShow { return false }
        }
        let lang = store.settings.language.lang
        let rule = target.candidate?.rule ?? quips.rule(for: target.category.rawValue, text: target.text,
            app: snapshot.appName, title: snapshot.windowTitle ?? "", lang: lang)
        var nextPicker = picker
        let chosen = nextPicker.pick(for: rule, lang: lang, persona: .init(rawValue: store.settings.persona.rawValue)!,
            pack: target.category == .rule ? store.builtin : .init(version: 1, rules: [], generic: [:]),
            disabledBuiltinIds: store.settings.disabledBuiltinIds, now: Date(), using: &random)
        guard let chosen else { return false }
        let source = target.category == .rule ? "rule" : target.category == .revisit ? "revisit" : "local"
        let shown = try await display(quote: target.text, lineIndex: target.lineIndex, range: target.range,
            quip: chosen, ruleID: rule.id, cooldownRuleID: ruleID, source: source, reason: attempt.reason,
            tick: tick, generation: generation)
        if shown {
            picker = nextPicker
            pickerRules[.init(bundleId: snapshot.bundleId, text: target.text), default: []].insert(rule.id)
            if target.category == .revisit { revisits[windowID!] = Date(); revisitAllowed = false }
        }
        return shown
    }

    @discardableResult
    private func showMark(_ mark: SpriteMark, id: UUID, source: String, reason: String, generation: Int) async throws -> Bool {
        guard generation == self.generation else { return false }
        defer { queuedPlaces.removeValue(forKey: id) }
        guard let snapshot = self.snapshot else { return false }
        // Delayed/API/cached marks locate again against the latest snapshot, not the request's indices.
        let screen = SpritePrompt.screen(in: snapshot)
        let lines = screen.lines.map { snapshot.textLines[$0.lineIndex] }
        let hint = screen.lines.firstIndex { $0.lineIndex == mark.lineIndex } ?? -1
        guard let hit = SpriteLocator.locate(quote: mark.quote, lineHint: hint, in: lines) else {
            log(snapshot, .mark, source: source, shown: false, reason: "quote-missing")
            return false
        }
        let index = screen.lines[hit.lineIndex].lineIndex
        guard !SpritePrompt.privacyRanges(in: snapshot.textLines[index].text).contains(where: { $0.overlaps(hit.range) }) else {
            log(snapshot, .mark, pick: index, source: source, shown: false, reason: "quote-missing")
            return false
        }
        return try await display(quote: mark.quote, lineIndex: index, range: hit.range, quip: mark.quip,
            ruleID: "sprite-model", cooldownRuleID: nil, source: source, reason: reason,
            tick: .mark, generation: generation, reservation: id)
    }

    private func display(quote: String, lineIndex: Int, range: Range<String.Index>, quip: Quip,
                         ruleID: String, cooldownRuleID: String?, source: String, reason: String,
                         tick: SpriteTick, generation: Int, reservation: UUID? = nil) async throws -> Bool {
        guard generation == self.generation else { return false }
        let id: UUID
        if let reservation { id = reservation }
        else {
            guard let reserved = reserve(quote: quote, lineIndex: lineIndex) else { return false }
            id = reserved
        }
        defer { queuedPlaces.removeValue(forKey: id) }
        try await waitForTyping(generation: generation, source: source)
        guard let snapshot = self.snapshot, let windowID, generation == self.generation,
              try canShow(snapshot, ruleID: cooldownRuleID, now: Date()) else { return false }
        let hit: (lineIndex: Int, range: Range<String.Index>)?
        if source == "model" || source == "cache" {
            let screen = SpritePrompt.screen(in: snapshot)
            let hint = screen.lines.firstIndex { $0.lineIndex == lineIndex } ?? -1
            let located = SpriteLocator.locate(quote: quote, lineHint: hint,
                in: screen.lines.map { snapshot.textLines[$0.lineIndex] })
            hit = located.map { (screen.lines[$0.lineIndex].lineIndex, $0.range) }
        } else {
            hit = lineIndex >= 0 ? SpriteLocator.locate(quote: quote, lineHint: lineIndex, in: snapshot.textLines) : nil
        }
        if lineIndex >= 0 && hit == nil { return false }
        let lineIndex = hit?.lineIndex ?? -1
        let range = hit?.range ?? range
        if lineIndex >= 0 && SpritePrompt.privacyRanges(in: snapshot.textLines[lineIndex].text).contains(where: { $0.overlaps(range) }) { return false }
        guard memory.status(key: .init(bundleId: snapshot.bundleId, text: quote), now: Date())?.isMarked != true else { return false }
        let key = screenKey
        let rect = lineIndex >= 0 ? try await sensor.textRect(lineIndex: lineIndex, range: range) : nil
        try await waitForTyping(generation: generation, source: source)
        if key != screenKey {
            return try await display(quote: quote, lineIndex: lineIndex, range: range, quip: quip,
                ruleID: ruleID, cooldownRuleID: cooldownRuleID, source: source, reason: reason,
                tick: tick, generation: generation, reservation: id)
        }
        let anchor = lineIndex >= 0 ? rect?.rect ?? sensor.unframedRect(lineIndex: lineIndex, range: range) : nil
        let line = lineIndex >= 0 ? sensor.placementLine(lineIndex: lineIndex, rect: rect?.rect, kind: rect?.kind) : nil
        guard try canShow(snapshot, ruleID: cooldownRuleID, now: Date()) else { return false }
        if let anchor, SpriteLocator.conflicts(.init(lineIndex: lineIndex, rect: anchor),
            with: positions(excluding: id, snapshot: snapshot)) { return false }
        let obstacles = snapshot.textLines.filter { $0.rect.intersects(snapshot.contentFrame) }.map(\.rect) + snapshot.sensitiveRects
        let shown = overlay.show(Narration(id: UUID().uuidString, quipID: quip.text, ruleID: ruleID,
            sequence: screenCount, text: quip.text, emoji: quip.emoji, language: quip.lang.rawValue,
            persona: .init(rawValue: quip.persona.rawValue)!, anchor: anchor, windowID: windowID,
            window: WindowGeometry(frame: snapshot.windowFrame, chromeHeight: chromeHeight),
            framed: rect != nil, line: line, obstacles: obstacles))
        if shown {
            forget(memory.mark(key: .init(bundleId: snapshot.bundleId, text: quote), quip: quip, lineHint: lineIndex, now: Date()))
            scheduler.recordShown(ruleID: cooldownRuleID, now: Date())
            lastShownAt = Date()
            screenCount += 1
            if let anchor { shownPlaces.append((quote, anchor.offsetBy(dx: -snapshot.windowFrame.minX, dy: -snapshot.windowFrame.minY))) }
        }
        log(snapshot, tick, pick: lineIndex, rect: rect?.kind.rawValue ?? "none", source: source,
            place: shown ? overlay.lastPlacement : "corner", shown: shown, reason: shown ? reason : "placement")
        return shown
    }

    private func scheduleLocalMarks(generation: Int) {
        let id = UUID()
        releases[id] = Task {
            defer { releases.removeValue(forKey: id) }
            do {
                var previous = 0.0
                for delay in SpriteTick.localBurst(level: store.settings.liveliness) {
                    try await Task.sleep(for: .seconds(delay - previous))
                    try Task.checkCancellation()
                    previous = delay
                    try await tick(.mark, switching: false, generation: generation)
                }
            } catch is CancellationError { return }
            catch { report(error) }
        }
    }

    private func replay(_ attempts: [SpriteTick.Attempt], generation: Int) {
        let queued = attempts.compactMap { attempt -> (UUID, SpriteTick.Attempt)? in
            guard let id = reserve(mark: attempt.mark!) else { return nil }
            return (id, attempt)
        }
        let releaseID = UUID()
        releases[releaseID] = Task {
            defer {
                releases.removeValue(forKey: releaseID)
                for (id, _) in queued { queuedPlaces.removeValue(forKey: id) }
            }
            do {
                for (index, (id, attempt)) in queued.enumerated() {
                    if index > 0 { try await Task.sleep(for: .seconds(SpriteTick.releaseGap(level: store.settings.liveliness))) }
                    try Task.checkCancellation()
                    try await waitForGap(generation: generation)
                    _ = try await showMark(attempt.mark!, id: id, source: "cache", reason: attempt.reason, generation: generation)
                }
            } catch is CancellationError { return }
            catch { report(error) }
        }
    }

    private func waitForGap(generation: Int) async throws {
        while let last = lastShownAt {
            let remaining = scheduler.settings.minGap - Date().timeIntervalSince(last)
            if remaining <= 0 { break }
            try await Task.sleep(for: .seconds(remaining))
        }
        try Task.checkCancellation()
        if generation != self.generation { throw CancellationError() }
    }

    private func enqueueModel(_ request: ModelRequest) {
        if modelTask != nil { requestPending = true; return }
        let now = Date()
        guard request.generation == generation, requestAllowed(now: now), modelBudget.begin(now: now) else { return }
        if let evicted = memory.recordRequest(key: request.key, now: now) { emptyScreens.remove(evicted) }
        windowRequests = windowRequests.filter { now.timeIntervalSince($0.value) < 60 }
        windowRequests[request.windowID] = now
        modelTask = Task { await generate(request, started: now) }
    }

    private func generate(_ request: ModelRequest, started: Date) async {
        let progress = SpriteRequestProgress()
        let (incoming, continuation) = AsyncStream<SpriteMark>.makeStream()
        let (stream, ready) = AsyncStream<(UUID, SpriteMark)>.makeStream()
        let cache = Task {
            var ids: [UUID] = []
            for await mark in incoming {
                let key = SpriteMemory.Key(bundleId: request.snapshot.bundleId, text: mark.quote)
                let marked = memory.status(key: key, now: Date())?.isMarked == true
                forget(memory.cache(key: key, quip: mark.quip, lineHint: mark.lineIndex, now: Date()))
                if !marked && request.generation == generation, let id = reserve(mark: mark) {
                    ids.append(id)
                    ready.yield((id, mark))
                }
            }
            ready.finish()
            return ids
        }
        let builtin = request.generator is LlamaGenerator
        let k = request.level == .rowdy ? 4 : 3
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)); try Task.checkCancellation() }
            catch { return }
            if progress.timeout() { modelTask?.cancel() }
        }
        let releaseID = UUID()
        let reader = Task {
            defer { releases.removeValue(forKey: releaseID) }
            var previous: Date?
            do {
                for await (id, mark) in stream {
                    try Task.checkCancellation()
                    guard request.generation == generation else { throw CancellationError() }
                    if !builtin, let previous {
                        let remaining = SpriteTick.releaseGap(level: request.level) - Date().timeIntervalSince(previous)
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                    }
                    try await waitForGap(generation: request.generation)
                    _ = try await showMark(mark, id: id, source: "model", reason: "ok", generation: request.generation)
                    previous = Date()
                }
            } catch is CancellationError { return }
            catch { report(error) }
        }
        releases[releaseID] = reader
        if request.snapshot.textSource == .ax {
            do {
                if try !sensor.boundsProbe() {
                    ocr = Task {
                        do { _ = try await sensor.visualLines() }
                        catch is CancellationError { return }
                        catch { report(error) }
                    }
                }
            } catch { report(error) }
        }
        var reason = "ok"
        do {
            _ = try await SpriteGenerator.generate(screen: request.screen, snapshot: request.snapshot,
                app: request.snapshot.appName, title: request.snapshot.windowTitle ?? "", exclude: request.exclude,
                persona: .init(rawValue: request.persona)!, lang: request.lang, k: k,
                generator: SpriteRequestGenerator(base: request.generator, progress: progress,
                    lines: request.screen.lines.map { request.snapshot.textLines[$0.lineIndex] },
                    lineIndices: request.screen.lines.map(\.lineIndex), onMissing: { index in
                        Task { @MainActor in
                            self.log(request.snapshot, .mark, pick: index, source: "model", shown: false, reason: "quote-missing")
                        }
                    })) { mark in
                    progress.accepted()
                    continuation.yield(mark)
                }
        } catch {
            if progress.metrics.timedOut { reason = "timeout" }
            else if Task.isCancelled || error is CancellationError { reason = "cancelled" }
            else { reason = "error"; report(error) }
        }
        let finished = Date()
        timeout.cancel()
        continuation.finish()
        let queuedIDs = await cache.value
        if reason == "cancelled" || reason == "timeout" { reader.cancel() }
        let prefill = if let llama = request.generator as? LlamaGenerator { await llama.lastPrefillSeconds } else { 0.0 }
        let metrics = progress.metrics
        if debug {
            let first = metrics.first.map { Int($0.timeIntervalSince(started) * 1000) } ?? -1
            FileHandle.standardError.write(Data("[sprite] model request k=\(k) lines=\(request.screen.lines.count) tokens≈\(Int(request.screen.tokens)) prefill=\(Int(prefill * 1000)) first=\(first) total=\(Int(finished.timeIntervalSince(started) * 1000)) marks=\(metrics.marks) located=\(metrics.located) reason=\(reason) exclude=\(request.exclude.count) started=\(Int(started.timeIntervalSince1970 * 1000))\n".utf8))
        }
        if reason == "ok" && metrics.located == 0 { emptyScreens.insert(request.key) }
        modelTask = nil
        let followupAllowed = reason == "ok" && metrics.located > 0
        Task {
            await reader.value
            for id in queuedIDs { queuedPlaces.removeValue(forKey: id) }
            if followupAllowed && request.generation == generation && request.key == screenKey {
                scheduleFollowup(generation: request.generation)
            }
        }
        if requestPending {
            requestPending = false
            scheduleLatestRequest()
        }
    }

    private func scheduleLatestRequest() {
        guard let windowID else { return }
        let generation = generation
        let delay = max(0, SpriteTick.windowRequestInterval(level: store.settings.liveliness)
            - Date().timeIntervalSince(windowRequests[windowID] ?? .distantPast))
        followup?.cancel()
        followup = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                try await tick(.snapshot, switching: false, generation: generation)
            } catch is CancellationError { return }
            catch { report(error) }
        }
    }

    private func scheduleFollowup(generation: Int) {
        guard let screenKey, (memory.screenStatus(key: screenKey)?.requests ?? 0) < SpriteTick.requestsPerScreen(level: store.settings.liveliness) else { return }
        followup = Task {
            do {
                try await Task.sleep(for: .seconds(SpriteTick.followupDelay(level: store.settings.liveliness)))
                try Task.checkCancellation()
                try await tick(.followup, switching: false, generation: generation)
            } catch is CancellationError { return }
            catch { report(error) }
        }
    }

    private func cancelScreen() {
        generation += 1
        releases.values.forEach { $0.cancel() }
        releases = [:]
        followup?.cancel()
        ocr?.cancel()
        modelTask?.cancel()
        requestPending = false
        queuedPlaces = [:]
    }

    private func report(_ error: any Error) {
        if Task.isCancelled { return }
        if let failure = error as? AXFailure, failure.code != .apiDisabled {
            FileHandle.standardError.write(Data("[sprite] skipped read: \(error)\n".utf8))
        } else { store.error = String(describing: error) }
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
        cancelScreen()
        overlay.dismissAll()
        snapshot = nil
        screenKey = nil
        screenCount = 0
        shownPlaces = []
        windowID = nil
        lastWindowFrameChange = .distantPast
    }

    private func log(_ snapshot: ContextSnapshot, _ tick: SpriteTick, pick: Int = -1, rect: String = "none",
                     source: String = "local", place: String = "corner", shown: Bool, reason: String) {
        guard debug else { return }
        let elapsed = Int(Date().timeIntervalSince(snapshot.capturedAt) * 1000)
        FileHandle.standardError.write(Data("[sprite] \(snapshot.bundleId) tick=\(tick.rawValue) pick=\(pick) rect=\(rect) source=\(source) place=\(place) show=\(shown) reason=\(reason) \(elapsed)ms\n".utf8))
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
