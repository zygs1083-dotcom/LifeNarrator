import Foundation
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
public final class SpriteBrain {
    private let sensor: any BrainSensor
    private let overlay: any BrainOverlay
    private let host: any BrainHost
    private let saidURL: URL
    private var said: SaidHistory
    private var settings: BrainSettings!
    private var content: BrainContent!
    private var generator: Result<(any TextGenerator)?, any Error>!
    private var revision = 0
    private var presenting = false
    private var presentationWaiters: [CheckedContinuation<Void, Never>] = []
    private let quips: SpriteQuips
    private var matcher = RuleMatcher(rules: [])
    private var scheduler = Scheduler()
    private var memory = SpriteMemory()
    private var configuredPersona = Persona.sharp
    private var picker = QuipPicker()
    private var pickerRules: [SpriteMemory.Key: Set<String>] = [:]
    private var random = SystemRandomNumberGenerator()
    private var generation = 0
    private var windowID: UInt32?
    private var chromeHeight: CGFloat = 52
    private var snapshot: ContextSnapshot?
    private var candidates: [Candidate] = []
    private var screenKey: UInt64?
    private var screenCount = 0
    private var shownPlaces: [(id: String, quote: String)] = []
    private var queuedPlaces: [UUID: (quote: String, rect: CGRect?)] = [:]
    private var visits: [UInt32: Date] = [:]
    private var revisits: [UInt32: Date] = [:]
    private var revisitAllowed = false
    private var lastShownAt: Date?
    private var lastWindowFrameChange = Date.distantPast
    private var releases: [UUID: Task<Void, Never>] = [:]
    private var followup: Task<Void, Never>?
    private var ocr: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var requestPending = false
    private var emptyScreens: Set<UInt64> = []
    private var windowRequests: [UInt32: Date] = [:]
    private var modelBudget = SpriteModelBudget(level: .lively)
    private var locatedByScreen: [UInt64: Int] = [:]
    private var cadence: Task<Void, Never>?
    private var ambientTask: Task<Void, Never>?
    private var ambientCache = SpriteAmbientCache()
    private var configuredLanguage: Lang?
    private var openerShown: [String: Date] = [:]
    private var enteredWindowAt = Date()
    private var appSeconds: [String: TimeInterval] = [:]
    private var activityApp: String?
    private var activitySince = Date()
    private var activityDay = Calendar.current.startOfDay(for: Date())
    private var windowSwitches: [Date] = []
    private var minuteStats = SpriteMinuteStats(now: Date())
    private var statsTask: Task<Void, Never>?
    private let debug = ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1"

    private struct ModelRequest {
        let snapshot: ContextSnapshot
        let screen: SpriteScreen
        let key: UInt64
        let windowID: UInt32
        let generation: Int
        let lang: Lang
        let persona: Persona
        let catalog: PersonaCatalog
        let level: Liveliness
        let exclude: [String]
        let generator: any TextGenerator
    }

    public init(sensor: any BrainSensor, overlay: any BrainOverlay, host: any BrainHost, saidURL: URL) throws {
        self.sensor = sensor
        self.overlay = overlay
        self.host = host
        self.saidURL = saidURL
        said = FileManager.default.fileExists(atPath: saidURL.path)
            ? try JSONDecoder().decode(SaidHistory.self, from: Data(contentsOf: saidURL)) : SaidHistory()
        quips = try SpriteQuips.loadBuiltin()
    }

    public func start() {
        if debug {
            statsTask = Task {
                do {
                    while true {
                        try await Task.sleep(for: .seconds(60))
                        FileHandle.standardError.write(Data((minuteStats.line(now: Date()) + "\n").utf8))
                    }
                } catch is CancellationError { return }
                catch { await report(error) }
            }
        }
    }

    // Defer configuration failures until the engine actually needs the corresponding service.
    public func configure(settings: BrainSettings, content: BrainContent, generator: Result<(any TextGenerator)?, any Error>) {
        let levelChanged = (self.settings?.liveliness ?? .lively) != settings.liveliness
        let personaChanged = configuredPersona != settings.persona
        self.settings = settings
        self.content = content
        self.generator = generator
        if personaChanged || configuredLanguage != settings.lang { ambientCache = SpriteAmbientCache() }
        configuredLanguage = settings.lang
        configuredPersona = settings.persona
        if personaChanged { memory = SpriteMemory(level: settings.liveliness) }
        scheduler.settings = .init(level: settings.liveliness)
        scheduler.settings.minGap = settings.markGap
        memory.level = settings.liveliness
        cancelScreen()
        if modelTask != nil { requestPending = true }
        if levelChanged {
            modelBudget = SpriteModelBudget(level: settings.liveliness)
            screenCount = 0
        }
        let dismiss = levelChanged || personaChanged || settings.paused
        if dismiss { shownPlaces = [] }
        let generation = generation
        Task {
            guard generation == self.generation else { return }
            if dismiss { await overlay.dismissAll() }
            guard generation == self.generation else { return }
            guard snapshot != nil else { return }
            matcher = await makeMatcher()
            guard generation == self.generation, let snapshot = self.snapshot else { return }
            candidates = matcher.candidates(in: snapshot, now: Date(), appChanged: true, hostChanged: true)
            runTick(.snapshot, switching: false)
            startCadence()
        }
    }

    private func makeMatcher() async -> RuleMatcher {
        let lowPower = await sensor.isLowPowerMode()
        return RuleMatcher(userRules: content.rules, builtinRules: content.builtin.rules,
            hasModel: settings.modelAvailable && settings.liveliness != .quiet && !lowPower,
            disabledBuiltinIds: settings.disabledBuiltinIds)
    }

    private func recordSaid(_ text: String, now: Date) throws {
        said.record(text, now: now)
        try JSONEncoder().encode(said).write(to: saidURL, options: .atomic)
    }

    private func positions(excluding id: UUID, snapshot: ContextSnapshot) async -> [SpriteLocator.Position] {
        var shown: [SpriteLocator.Position] = []
        for entry in shownPlaces {
            let rect = await overlay.highlight(id: entry.id)
            shown.append(.init(lineIndex: SpriteLocator.locate(quote: entry.quote, lineHint: -1, in: snapshot.textLines)?.lineIndex ?? -1,
                rect: rect))
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

    private func reserve(mark: SpriteMark, generation: Int) async -> UUID? {
        guard let snapshot else { return nil }
        let screen = SpritePrompt.screen(in: snapshot)
        let lines = screen.lines.map { snapshot.textLines[$0.lineIndex] }
        let hint = screen.lines.firstIndex { $0.lineIndex == mark.lineIndex } ?? -1
        guard let hit = SpriteLocator.locate(quote: mark.quote, lineHint: hint, in: lines) else { return nil }
        return await reserve(quote: mark.quote, lineIndex: screen.lines[hit.lineIndex].lineIndex, generation: generation)
    }

    private func reserve(quote: String, lineIndex: Int, generation: Int) async -> UUID? {
        guard generation == self.generation, let snapshot else { return nil }
        let revision = revision
        guard memory.status(key: .init(bundleId: snapshot.bundleId, text: quote), now: Date())?.isMarked != true,
              !queuedPlaces.values.contains(where: { normalized($0.quote) == normalized(quote) }) else { return nil }
        let id = UUID()
        let hit = lineIndex >= 0 ? SpriteLocator.locate(quote: quote, lineHint: lineIndex, in: snapshot.textLines) : nil
        if lineIndex >= 0 && hit == nil { return nil }
        let lineIndex = hit?.lineIndex ?? -1
        let rect = hit.map { RuleMatcher.estimatedRect(for: snapshot.textLines[$0.lineIndex], range: $0.range) }
        let positions = await positions(excluding: id, snapshot: snapshot)
        guard generation == self.generation else { return nil }
        if revision != self.revision {
            return await reserve(quote: quote, lineIndex: lineIndex, generation: generation)
        }
        guard memory.status(key: .init(bundleId: snapshot.bundleId, text: quote), now: Date())?.isMarked != true,
              !queuedPlaces.values.contains(where: { normalized($0.quote) == normalized(quote) }) else { return nil }
        if let rect, SpriteLocator.conflicts(.init(lineIndex: lineIndex, rect: rect), with: positions) { return nil }
        queuedPlaces[id] = (quote, rect?.offsetBy(dx: -snapshot.windowFrame.minX, dy: -snapshot.windowFrame.minY))
        return id
    }

    private func beginPresentation() async -> Bool {
        if presenting {
            await withCheckedContinuation { presentationWaiters.append($0) }
            return true
        }
        presenting = true
        return false
    }

    private func endPresentation() {
        if presentationWaiters.isEmpty { presenting = false }
        else { presentationWaiters.removeFirst().resume() }
    }

    private func checkGeneration(_ generation: Int) throws {
        try Task.checkCancellation()
        if generation != self.generation { throw CancellationError() }
    }

    private func waitForTyping(generation: Int, source: String) async throws {
        var logged = false
        while true {
            while try await sensor.isTyping(now: Date()) {
                try Task.checkCancellation()
                if generation != self.generation { throw CancellationError() }
                if !logged, let snapshot {
                    log(snapshot, .mark, source: source, shown: false, reason: "deferred-typing")
                    logged = true
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            try await waitForGap(generation: generation)
            let typing = try await sensor.isTyping(now: Date())
            try checkGeneration(generation)
            if !typing { return }
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
            catch { await report(error) }
        }
    }

    public func snapshot(_ snapshot: ContextSnapshot, windowID: UInt32, change: ContextChange) {
        let id = windowID
        let screen = SpritePrompt.screen(in: snapshot)
        let key = stableHash("\(id)\n" + screen.lines.map { normalized($0.text) }.joined(separator: "\n"))
        let switching = SpriteTick.resetsWindow(appChanged: change.appChanged, windowChanged: change.windowChanged)
        let changed = key != screenKey
        if self.snapshot?.textLines != snapshot.textLines || self.snapshot?.windowFrame != snapshot.windowFrame
            || self.snapshot?.contentFrame != snapshot.contentFrame || self.snapshot?.sensitiveRects != snapshot.sensitiveRects {
            revision += 1
        }
        self.snapshot = snapshot
        self.windowID = id
        chromeHeight = snapshot.contentFrame.minY - snapshot.windowFrame.minY
        screenKey = key
        if switching {
            cancelScreen()
            screenCount = 0
            shownPlaces = []
        }
        if switching {
            let now = snapshot.capturedAt
            updateActivity(now: now)
            activityApp = snapshot.bundleId
            enteredWindowAt = now
            windowSwitches = windowSwitches.filter { now.timeIntervalSince($0) < 600 }
            windowSwitches.append(now)
            startCadence()
            visits = visits.filter { now.timeIntervalSince($0.value) < 120 }
            revisits = revisits.filter { now.timeIntervalSince($0.value) < 600 }
            revisitAllowed = SpriteTick.revisitAllowed(lastVisit: visits[id], lastRevisit: revisits[id], now: now)
            visits[id] = now
        }
        if modelTask != nil && (changed || switching) { requestPending = true }
        else if changed && !switching && Date().timeIntervalSince(windowRequests[id] ?? .distantPast)
            < SpriteTick.windowRequestInterval(level: settings.liveliness) { scheduleLatestRequest() }
        // Identical AX notifications must not restart releases or create another request.
        let generation = generation
        Task {
            guard generation == self.generation else { return }
            if switching { await overlay.dismissAll() } else { await overlay.follow() }
            guard generation == self.generation else { return }
            let matcher = await makeMatcher()
            guard generation == self.generation, let latest = self.snapshot else { return }
            self.matcher = matcher
            candidates = matcher.candidates(in: latest, now: latest.capturedAt,
                appChanged: switching, hostChanged: switching || change.hostChanged)
            if changed || switching { runTick(.snapshot, switching: switching) }
        }
    }

    private func runTick(_ kind: SpriteTick, switching: Bool = false) {
        let generation = generation
        Task {
            do { try await tick(kind, switching: switching, generation: generation) }
            catch is CancellationError { return }
            catch { await report(error) }
        }
    }

    private func quietReason(_ snapshot: ContextSnapshot, now: Date) async throws -> String? {
        if settings.paused { return "paused" }
        if settings.blacklist.contains(snapshot.bundleId) { return "blacklisted" }
        if snapshot.pid == settings.ownProcessID { return "own-window" }
        var current = snapshot
        current.secureFocused = try await sensor.isSecureFocused()
        return SpriteTick.quietReason(in: current, typing: false,
                                      moving: now.timeIntervalSince(lastWindowFrameChange) < 0.5)
    }

    private func requestAllowed(now: Date) -> Bool {
        guard modelTask == nil, let windowID, let screenKey, !emptyScreens.contains(screenKey) else { return false }
        return now.timeIntervalSince(windowRequests[windowID] ?? .distantPast) >= SpriteTick.windowRequestInterval(level: settings.liveliness)
            && modelBudget.allows(now: now)
    }

    private func tick(_ kind: SpriteTick, switching: Bool, generation: Int) async throws {
        try checkGeneration(generation)
        let idle = await sensor.idleSeconds()
        let lowPower = await sensor.isLowPowerMode()
        try checkGeneration(generation)
        if kind == .followup && settings.liveliness == .rowdy && idle >= 60 { return }
        guard let snapshot else { return }
        let revision = revision
        let now = Date()
        let reason = try await quietReason(snapshot, now: now)
        try checkGeneration(generation)
        if revision != self.revision { return try await tick(kind, switching: switching, generation: generation) }
        if let reason {
            log(snapshot, kind, shown: false, reason: reason)
            // Stage Manager animates new windows in from a thumbnail; read again once it has grown.
            if reason == "small" && switching {
                Task {
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                    guard generation == self.generation else { return }
                    await sensor.refresh()
                }
            }
            // Moving, resizing and the full-screen animation are quiet; look again once the window has settled.
            if reason == "moving" {
                Task {
                    do { try await Task.sleep(for: .seconds(0.6)) }
                    catch { return }
                    guard generation == self.generation else { return }
                    runTick(kind, switching: switching)
                }
            }
            return
        }
        let level = settings.liveliness
        if level == .rowdy && kind == .followup {
            let allowed = await rowdyPrefetchAllowed(now: now)
            try checkGeneration(generation)
            guard allowed else { return }
        }
        let generator = level != .quiet && !lowPower ? try self.generator.get() : nil
        if switching { try await showOpener(snapshot, now: now) }
        try checkGeneration(generation)
        guard let snapshot = self.snapshot, let screenKey else { return }
        let screen = SpritePrompt.screen(in: snapshot)
        let attempts = SpriteTick.attempts(in: snapshot, candidates: candidates.filter {
            !(level == .rowdy && $0.rule.source == .builtin && ($0.rule.kind == .app || $0.rule.kind == .site))
        }, memory: memory,
            level: level, switching: switching, scheduler: scheduler, revisitAllowed: revisitAllowed,
            screen: screen, screenKey: screenKey, hasModel: generator != nil,
            requestAllowed: requestAllowed(now: now), now: now)
        releaseTargets(attempts.filter { $0.target?.category == .rule }, tick: kind, generation: generation)
        guard generation == self.generation else { return }
        let marks = attempts.filter { attempt in
            guard let mark = attempt.mark else { return false }
            return !queuedPlaces.values.contains { normalized($0.quote) == normalized(mark.quote) }
        }
        if !marks.isEmpty { await replay(marks, generation: generation) }
        try checkGeneration(generation)
        guard revision == self.revision else { return }
        let prefetch = SpriteTick.prefetchAllowed(level: level, succeeded: true,
            located: locatedByScreen[screenKey] ?? 0, queued: queuedPlaces.count,
            requests: memory.screenStatus(key: screenKey, now: now)?.requests ?? 0,
            budgetAllowed: requestAllowed(now: now), idleFor: idle)
        if (marks.isEmpty && attempts.contains(where: { $0.reason == "request" }) || prefetch), let generator {
            log(snapshot, kind, source: "model", shown: false, reason: "waiting-model")
            enqueueModel(ModelRequest(snapshot: snapshot, screen: screen, key: screenKey, windowID: windowID!,
                generation: generation, lang: settings.lang,
                persona: settings.persona, catalog: content.personas, level: level,
                exclude: level == .rowdy
                    ? memory.requestQuotes(bundleId: snapshot.bundleId, queued: queuedPlaces.values.map(\.quote), now: now)
                    : memory.shownQuotes(bundleId: snapshot.bundleId, now: now), generator: generator))
        } else if marks.isEmpty {
            let local = attempts.filter { $0.target != nil && $0.target?.category != .rule }
            releaseTargets(local, tick: kind, generation: generation)
            if generator == nil && kind == .snapshot { scheduleLocalMarks(generation: generation) }
            if local.isEmpty { log(snapshot, kind, shown: false, reason: attempts.isEmpty ? "no-targets" : "unavailable") }
        }
    }

    private func canShow(_ snapshot: ContextSnapshot, ruleID: String?, now: Date) async throws -> Bool {
        if let reason = try await quietReason(snapshot, now: now) {
            log(snapshot, .mark, shown: false, reason: reason)
            return false
        }
        let level = settings.liveliness
        if level != .quiet && screenCount >= SpriteTick.screenLimit(level: level, maxOnScreen: settings.maxOnScreen) {
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
        guard try await canShow(snapshot, ruleID: ruleID, now: Date()) else { return false }
        try checkGeneration(generation)
        guard let snapshot = self.snapshot else { return false }
        if let candidate = target.candidate, let configuration = settings.systemOne {
            do {
                let plan = SystemOneDecision.plan(snapshot: snapshot, candidates: [candidate], freeComments: false,
                    needsGeneration: false, now: Date(), model: configuration.model.isEmpty ? "jev-latest" : configuration.model)
                var response: DecisionResponse?
                if !plan.request.questions.isEmpty {
                    let connection = try configuration.connection.get()
                    let client = SystemOneClient(baseURL: connection.url, key: connection.key)
                    response = try await client.decide(plan.request)
                    guard generation == self.generation else { return false }
                }
                guard let snapshot = self.snapshot else { return false }
                if try !SystemOneDecision.evaluate(response, plan: plan, snapshot: snapshot).shouldShow { return false }
            } catch is CancellationError { throw CancellationError() }
            catch {
                await report(error)
                return false
            }
        }
        try checkGeneration(generation)
        guard let snapshot = self.snapshot else { return false }
        let lang = settings.lang
        let rule = target.candidate?.rule ?? quips.rule(for: target.category.rawValue, text: target.text,
            app: snapshot.appName, title: snapshot.windowTitle ?? "", lang: lang)
        var nextPicker = picker
        let chosen = nextPicker.pick(for: rule, lang: lang, persona: settings.persona,
            pack: target.category == .rule ? content.builtin : .init(version: 1, rules: [], generic: [:]),
            disabledBuiltinIds: settings.disabledBuiltinIds, now: Date(),
            isRepeat: { self.said.isRepeat($0, now: Date()) }, using: &random, catalog: content.personas)
        guard let chosen else { return false }
        let source = target.category == .rule ? "rule" : target.category == .revisit ? "revisit" : "local"
        let shown = try await display(quote: target.text, lineIndex: target.lineIndex, range: target.range,
            quip: chosen, ruleID: rule.id, cooldownRuleID: ruleID, source: source, reason: attempt.reason,
            tick: tick, generation: generation)
        if shown && generation == self.generation {
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
        try checkGeneration(generation)
        let id: UUID
        if let reservation { id = reservation }
        else {
            guard let reserved = await reserve(quote: quote, lineIndex: lineIndex, generation: generation) else { return false }
            id = reserved
        }
        defer { queuedPlaces.removeValue(forKey: id) }
        while true {
            try await waitForTyping(generation: generation, source: source)
            try checkGeneration(generation)
            guard let snapshot = self.snapshot, let windowID else { return false }
            let revision = revision
            guard try await canShow(snapshot, ruleID: cooldownRuleID, now: Date()) else { return false }
            try checkGeneration(generation)
            if revision != self.revision { continue }
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
            let utf16 = lineIndex >= 0 ? NSRange(range, in: snapshot.textLines[lineIndex].text) : NSRange(location: 0, length: 0)
            let rect = lineIndex >= 0 ? try await sensor.textRect(lineIndex: lineIndex, range: utf16) : nil
            try checkGeneration(generation)
            if revision != self.revision { continue }
            let track = lineIndex >= 0 ? try await sensor.markTrack(lineIndex: lineIndex, kind: rect?.kind) : nil
            try checkGeneration(generation)
            if revision != self.revision { continue }
            try await waitForTyping(generation: generation, source: source)
            try checkGeneration(generation)
            if revision != self.revision { continue }
            var anchor = rect?.rect
            if lineIndex >= 0 && anchor == nil {
                anchor = await sensor.unframedRect(lineIndex: lineIndex, range: utf16)
                try checkGeneration(generation)
                if revision != self.revision { continue }
            }
            let line = lineIndex >= 0 ? await sensor.placementLine(lineIndex: lineIndex, rect: anchor!, kind: rect?.kind) : nil
            try checkGeneration(generation)
            if revision != self.revision { continue }
            let waited = await beginPresentation()
            defer { endPresentation() }
            if waited { try await waitForTyping(generation: generation, source: source) }
            try checkGeneration(generation)
            if revision != self.revision { continue }
            guard try await canShow(snapshot, ruleID: cooldownRuleID, now: Date()) else { return false }
            try checkGeneration(generation)
            if revision != self.revision { continue }
            let positions = await positions(excluding: id, snapshot: snapshot)
            try checkGeneration(generation)
            if revision != self.revision { continue }
            if let anchor, SpriteLocator.conflicts(.init(lineIndex: lineIndex, rect: anchor), with: positions) { return false }
            let obstacles = await sensor.placementObstacles(in: snapshot.contentFrame) + snapshot.sensitiveRects
            try checkGeneration(generation)
            if revision != self.revision { continue }
            if said.isRepeat(quip.text, now: Date()) {
                log(snapshot, tick, pick: lineIndex, source: source, shown: false, reason: "repeat")
                return false
            }
            let narrationID = UUID().uuidString
            let result = await overlay.show(Narration(id: narrationID, quipID: quip.text, ruleID: ruleID,
                sequence: screenCount, text: quip.text, emoji: quip.emoji, language: quip.lang.rawValue,
                persona: quip.persona, anchor: anchor, windowID: windowID,
                window: WindowGeometry(frame: snapshot.windowFrame, chromeHeight: chromeHeight),
                framed: rect != nil, line: line, obstacles: obstacles, trackID: track))
            if result.shown {
                try recordSaid(quip.text, now: Date())
                if generation == self.generation {
                    forget(memory.mark(key: .init(bundleId: snapshot.bundleId, text: quote), quip: quip, lineHint: lineIndex, now: Date()))
                    scheduler.recordShown(ruleID: cooldownRuleID, now: Date())
                    lastShownAt = Date()
                    screenCount += 1
                    if anchor != nil { shownPlaces.append((narrationID, quote)) }
                    await overlay.follow()
                }
            }
            log(snapshot, tick, pick: lineIndex, rect: rect?.kind.rawValue ?? "none", source: source,
                place: result.shown ? result.placement : "corner", shown: result.shown, reason: result.shown ? reason : "placement",
                quipHash: result.shown ? SaidHistory.textHash(quip.text) : nil)
            return result.shown
        }
    }

    private func scheduleLocalMarks(generation: Int) {
        let id = UUID()
        releases[id] = Task {
            defer { releases.removeValue(forKey: id) }
            do {
                var previous = 0.0
                for delay in SpriteTick.localBurst(level: settings.liveliness) {
                    try await Task.sleep(for: .seconds(delay - previous))
                    try Task.checkCancellation()
                    previous = delay
                    try await tick(.mark, switching: false, generation: generation)
                }
            } catch is CancellationError { return }
            catch { await report(error) }
        }
    }

    private func replay(_ attempts: [SpriteTick.Attempt], generation: Int) async {
        var queued: [(UUID, SpriteTick.Attempt)] = []
        for attempt in attempts {
            if let id = await reserve(mark: attempt.mark!, generation: generation) { queued.append((id, attempt)) }
        }
        let releaseID = UUID()
        releases[releaseID] = Task {
            defer {
                releases.removeValue(forKey: releaseID)
                for (id, _) in queued { queuedPlaces.removeValue(forKey: id) }
            }
            do {
                for (id, attempt) in queued {
                    try Task.checkCancellation()
                    try await waitForGap(generation: generation)
                    _ = try await showMark(attempt.mark!, id: id, source: "cache", reason: attempt.reason, generation: generation)
                }
            } catch is CancellationError { return }
            catch { await report(error) }
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
        ambientTask?.cancel()
        if let evicted = memory.recordRequest(key: request.key, now: now) {
            emptyScreens.remove(evicted)
            locatedByScreen.removeValue(forKey: evicted)
        }
        minuteStats.begin(now: now)
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
                guard request.persona == settings.persona else { continue }
                let key = SpriteMemory.Key(bundleId: request.snapshot.bundleId, text: mark.quote)
                let marked = memory.status(key: key, now: Date())?.isMarked == true
                forget(memory.cache(key: key, quip: mark.quip, lineHint: mark.lineIndex, now: Date()))
                if !marked && request.generation == generation, let id = await reserve(mark: mark, generation: request.generation) {
                    ids.append(id)
                    ready.yield((id, mark))
                }
            }
            ready.finish()
            return ids
        }
        let k = SpriteTick.requestCount(level: request.level, maxOnScreen: settings.maxOnScreen)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)); try Task.checkCancellation() }
            catch { return }
            if progress.timeout() { modelTask?.cancel() }
        }
        let releaseID = UUID()
        let reader = Task {
            defer { releases.removeValue(forKey: releaseID) }
            do {
                for await (id, mark) in stream {
                    try Task.checkCancellation()
                    guard request.generation == generation else { throw CancellationError() }
                    try await waitForGap(generation: request.generation)
                    _ = try await showMark(mark, id: id, source: "model", reason: "ok", generation: request.generation)
                    let allowed = await rowdyPrefetchAllowed(now: Date())
                    try checkGeneration(request.generation)
                    if allowed { runTick(.followup) }
                }
            } catch is CancellationError { return }
            catch { await report(error) }
        }
        releases[releaseID] = reader
        if request.snapshot.textSource == .ax {
            do {
                let bounds = try await sensor.boundsProbe()
                try checkGeneration(request.generation)
                if !bounds {
                    ocr = Task {
                        guard request.generation == generation else { return }
                        await sensor.startVisualLines()
                    }
                }
            } catch { await report(error) }
        }
        let said = said
        var reason = "ok"
        do {
            _ = try await SpriteGenerator.generate(screen: request.screen, snapshot: request.snapshot,
                app: request.snapshot.appName, title: request.snapshot.windowTitle ?? "", exclude: request.exclude,
                persona: request.persona, lang: request.lang, k: k, recent: said.recent(8),
                generator: SpriteRequestGenerator(base: request.generator, progress: progress,
                    lines: request.screen.lines.map { request.snapshot.textLines[$0.lineIndex] },
                    lineIndices: request.screen.lines.map(\.lineIndex), onMissing: { index in
                        Task { @MainActor in
                            self.log(request.snapshot, .mark, pick: index, source: "model", shown: false, reason: "quote-missing")
                        }
                    }), catalog: request.catalog, isRepeat: { said.isRepeat($0, now: Date()) }) { mark in
                    progress.accepted()
                    continuation.yield(mark)
                }
        } catch {
            if progress.metrics.timedOut { reason = "timeout" }
            else if Task.isCancelled || error is CancellationError { reason = "cancelled" }
            else { reason = "error"; await report(error) }
        }
        let finished = Date()
        minuteStats.end(now: finished, wasCancelled: reason == "cancelled")
        timeout.cancel()
        continuation.finish()
        let queuedIDs = await cache.value
        if reason == "cancelled" || reason == "timeout" { reader.cancel() }
        let prefill = if let llama = request.generator as? any GeneratorMetrics { await llama.lastPrefillSeconds } else { 0.0 }
        let metrics = progress.metrics
        if debug {
            let first = metrics.first.map { Int($0.timeIntervalSince(started) * 1000) } ?? -1
            FileHandle.standardError.write(Data("[sprite] model request k=\(k) lines=\(request.screen.lines.count) tokens≈\(Int(request.screen.tokens)) prefill=\(Int(prefill * 1000)) first=\(first) total=\(Int(finished.timeIntervalSince(started) * 1000)) marks=\(metrics.marks) located=\(metrics.located) reason=\(reason) exclude=\(request.exclude.count) started=\(Int(started.timeIntervalSince1970 * 1000))\n".utf8))
        }
        if reason == "ok" {
            locatedByScreen[request.key] = metrics.located
            if metrics.located == 0 { emptyScreens.insert(request.key) }
        }
        modelTask = nil
        if request.level == .rowdy && reason == "ok" && metrics.located > 0
            && request.generation == generation && request.key == screenKey {
            runTick(.followup)
        }
        let followupAllowed = reason == "ok" && metrics.located > 0
        Task {
            await reader.value
            for id in queuedIDs { queuedPlaces.removeValue(forKey: id) }
            if request.level != .rowdy && followupAllowed && request.generation == generation && request.key == screenKey {
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
        let delay = max(0, SpriteTick.windowRequestInterval(level: settings.liveliness)
            - Date().timeIntervalSince(windowRequests[windowID] ?? .distantPast))
        followup?.cancel()
        followup = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                try await tick(.snapshot, switching: false, generation: generation)
            } catch is CancellationError { return }
            catch { await report(error) }
        }
    }

    private func scheduleFollowup(generation: Int) {
        guard let screenKey, (memory.screenStatus(key: screenKey, now: Date())?.requests ?? 0) < SpriteTick.requestsPerScreen(level: settings.liveliness) else { return }
        followup = Task {
            do {
                try await Task.sleep(for: .seconds(SpriteTick.followupDelay(level: settings.liveliness)))
                try Task.checkCancellation()
                try await tick(.followup, switching: false, generation: generation)
            } catch is CancellationError { return }
            catch { await report(error) }
        }
    }

    private func rowdyPrefetchAllowed(now: Date) async -> Bool {
        let idle = await sensor.idleSeconds()
        guard let screenKey else { return false }
        return SpriteTick.prefetchAllowed(level: settings.liveliness, succeeded: true,
            located: locatedByScreen[screenKey] ?? 0, queued: queuedPlaces.count,
            requests: memory.screenStatus(key: screenKey, now: now)?.requests ?? 0,
            budgetAllowed: requestAllowed(now: now), idleFor: idle)
    }

    private func startCadence() {
        cadence?.cancel()
        guard settings.liveliness != .quiet else { return }
        let generation = generation
        cadence = Task {
            do {
                while true {
                    try await Task.sleep(for: .seconds(1))
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    let idle = await sensor.idleSeconds()
                    try checkGeneration(generation)
                    if idle >= 60 { continue }
                    let allowed = await rowdyPrefetchAllowed(now: Date())
                    try checkGeneration(generation)
                    if allowed { try await tick(.followup, switching: false, generation: generation) }
                    try checkGeneration(generation)
                    try await ambientPulse()
                }
            } catch is CancellationError { return }
            catch { await report(error) }
        }
    }

    private func updateActivity(now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        if activityDay != day {
            appSeconds = [:]
            activityDay = day
            activitySince = max(activitySince, day)
        }
        if let activityApp { appSeconds[activityApp, default: 0] += now.timeIntervalSince(activitySince) }
        activitySince = now
    }

    private func ambientPulse() async throws {
        let generation = generation
        let idle = await sensor.idleSeconds()
        let typing = try await sensor.isTyping(now: Date())
        let lowPower = await sensor.isLowPowerMode()
        let lastTyped = await sensor.lastTypedAt()
        try checkGeneration(generation)
        guard idle < 60, let snapshot, let screenKey else { return }
        let revision = revision
        guard try await quietReason(snapshot, now: Date()) == nil else { return }
        try checkGeneration(generation)
        guard revision == self.revision else { return }
        let now = Date()
        let settings = self.settings!
        let exhausted = locatedByScreen[screenKey] == 0 || emptyScreens.contains(screenKey)
            || (memory.screenStatus(key: screenKey, now: now)?.requests ?? 0) >= SpriteTick.requestsPerScreen(level: settings.liveliness)
        guard SpriteTick.ambientAllowed(level: settings.liveliness, dwell: now.timeIntervalSince(enteredWindowAt),
            sinceLast: now.timeIntervalSince(lastShownAt ?? enteredWindowAt), exhausted: exhausted,
            typing: typing, hasModel: !lowPower, idleFor: idle),
            queuedPlaces.isEmpty, modelTask == nil, !requestPending,
            let generator = try self.generator.get() else { return }
        guard scheduler.canShow(ruleID: nil, now: now) else { return }
        if let metrics = generator as? any GeneratorMetrics, await metrics.isBusy { return }
        try checkGeneration(generation)
        guard revision == self.revision else { return }
        if let quip = ambientCache.take(app: snapshot.bundleId, now: now,
            isRepeat: { said.isRepeat($0, now: now) }) {
            _ = try await displayCorner(quip, ruleID: "sprite-ambient", source: "ambient")
            return
        }
        guard ambientTask == nil, !ambientCache.contains(app: snapshot.bundleId, now: now),
              modelBudget.begin(now: now) else { return }
        updateActivity(now: now)
        windowSwitches.removeAll { now.timeIntervalSince($0) >= 600 }
        let time = Calendar.current.dateComponents([.hour, .minute], from: now)
        let signals = SpriteAmbientSignals(app: snapshot.appName, title: snapshot.windowTitle ?? "",
            minutes: Int(appSeconds[snapshot.bundleId, default: 0] / 60), hour: time.hour!, minute: time.minute!,
            switches: windowSwitches.count, typedRecently: now.timeIntervalSince(lastTyped) < 60)
        let recent = said.recent(8)
        let catalog = content.personas
        minuteStats.begin(now: now)
        ambientTask = Task {
            defer {
                ambientTask = nil
                minuteStats.end(now: Date(), wasCancelled: Task.isCancelled)
            }
            do {
                let lines = try await SpriteAmbient.generate(signals: signals, persona: settings.persona,
                    lang: settings.lang, recent: recent, generator: generator, catalog: catalog)
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                ambientCache.store(lines, app: snapshot.bundleId, now: Date())
                try await ambientPulse()
            } catch is CancellationError { return }
            catch { await report(error) }
        }
    }

    private func showOpener(_ snapshot: ContextSnapshot, now: Date) async throws {
        guard settings.liveliness == .rowdy else { return }
        let generation = generation
        let rules = content.builtin.rules.filter { $0.kind == .app || $0.kind == .site }
        let matches = RuleMatcher(rules: rules, disabledBuiltinIds: settings.disabledBuiltinIds)
            .candidates(in: snapshot, now: now, appChanged: true, hostChanged: true)
        for candidate in matches {
            let rule = candidate.rule
            guard SpriteTick.openerAllowed(level: settings.liveliness, kind: rule.kind,
                last: openerShown[rule.id], now: now) else { continue }
            var nextPicker = picker
            guard let quip = nextPicker.pick(for: rule, lang: settings.lang,
                persona: settings.persona, pack: .init(version: 1, rules: [], generic: [:]), now: now,
                isRepeat: { said.isRepeat($0, now: now) }, using: &random, catalog: content.personas) else { continue }
            let shown = try await displayCorner(quip, ruleID: rule.id, source: "opener")
            try checkGeneration(generation)
            if shown {
                picker = nextPicker
                openerShown[rule.id] = now
                break
            }
        }
    }

    @discardableResult
    private func displayCorner(_ quip: Quip, ruleID: String, source: String) async throws -> Bool {
        let generation = generation
        while true {
            let now = Date()
            guard let snapshot, let windowID else { return false }
            let revision = revision
            let reason = try await quietReason(snapshot, now: now)
            try checkGeneration(generation)
            if revision != self.revision { continue }
            guard reason == nil else { return false }
            let typing = try await sensor.isTyping(now: now)
            try checkGeneration(generation)
            if revision != self.revision { continue }
            guard !typing, scheduler.canShow(ruleID: nil, now: now, ignoringGap: source == "opener") else { return false }
            let waited = await beginPresentation()
            defer { endPresentation() }
            try checkGeneration(generation)
            if revision != self.revision { continue }
            if waited {
                let reason = try await quietReason(snapshot, now: Date())
                let typing = try await sensor.isTyping(now: Date())
                try checkGeneration(generation)
                if revision != self.revision { continue }
                guard reason == nil, !typing,
                    scheduler.canShow(ruleID: nil, now: Date(), ignoringGap: source == "opener") else { return false }
            }
            if source == "opener", !SpriteTick.openerAllowed(level: settings.liveliness,
                kind: .app, last: openerShown[ruleID], now: now) { return false }
            if said.isRepeat(quip.text, now: now) {
                log(snapshot, .mark, source: source, shown: false, reason: "repeat")
                return false
            }
            let result = await overlay.show(Narration(id: UUID().uuidString, quipID: quip.text, ruleID: ruleID,
                sequence: screenCount, text: quip.text, emoji: quip.emoji, language: quip.lang.rawValue,
                persona: quip.persona, anchor: nil, windowID: windowID,
                window: WindowGeometry(frame: snapshot.windowFrame, chromeHeight: chromeHeight), framed: false))
            if result.shown {
                try recordSaid(quip.text, now: now)
                if generation == self.generation {
                    scheduler.recordShown(ruleID: nil, now: now)
                    lastShownAt = now
                    if source == "opener" { openerShown[ruleID] = now }
                }
            }
            log(snapshot, .mark, source: source, shown: result.shown, reason: result.shown ? "ok" : "placement",
                quipHash: result.shown ? SaidHistory.textHash(quip.text) : nil)
            return result.shown
        }
    }

    private func cancelScreen() {
        generation += 1
        releases.values.forEach { $0.cancel() }
        releases = [:]
        followup?.cancel()
        cadence?.cancel()
        ambientTask?.cancel()
        ocr?.cancel()
        modelTask?.cancel()
        requestPending = false
        queuedPlaces = [:]
    }

    private func report(_ error: any Error) async {
        if Task.isCancelled { return }
        await host.report(error)
    }

    private func forget(_ key: SpriteMemory.Key?) {
        guard let key else { return }
        for id in pickerRules.removeValue(forKey: key) ?? [] { picker.forget(ruleID: id) }
    }

    public func windowFrameChanged(_ frame: CGRect) {
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
        revision += 1
        let window = WindowGeometry(frame: frame, chromeHeight: chromeHeight)
        let generation = generation
        Task {
            guard generation == self.generation else { return }
            await overlay.windowFrameChanged(windowID: windowID, window: window)
        }
    }

    public func windowChanged() {
        updateActivity(now: Date())
        activityApp = nil
        cancelScreen()
        let generation = generation
        Task {
            guard generation == self.generation else { return }
            await overlay.dismissAll()
        }
        revision += 1
        snapshot = nil
        screenKey = nil
        screenCount = 0
        shownPlaces = []
        windowID = nil
        lastWindowFrameChange = .distantPast
    }

    private func log(_ snapshot: ContextSnapshot, _ tick: SpriteTick, pick: Int = -1, rect: String = "none",
                     source: String = "local", place: String = "corner", shown: Bool, reason: String,
                     quipHash: UInt32? = nil) {
        guard debug else { return }
        minuteStats.record(source: source, shown: shown, repeatRejected: reason == "repeat")
        let elapsed = Int(Date().timeIntervalSince(snapshot.capturedAt) * 1000)
        let hash = quipHash.map { " qh=" + String(format: "%08x", $0) } ?? ""
        FileHandle.standardError.write(Data("[sprite] \(snapshot.bundleId) tick=\(tick.rawValue) pick=\(pick) rect=\(rect) source=\(source) place=\(place) show=\(shown) reason=\(reason) \(elapsed)ms\(hash)\n".utf8))
    }

}
