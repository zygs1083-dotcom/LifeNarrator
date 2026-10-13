import AppKit
import ApplicationServices
import NarratorCore

public struct ContextChange: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case appChanged, windowChanged, hostChanged, contentChanged }
    public let appChanged: Bool
    public let windowChanged: Bool
    public let hostChanged: Bool
    public var reason: Reason { appChanged ? .appChanged : windowChanged ? .windowChanged : hostChanged ? .hostChanged : .contentChanged }
}

// The holder also tears down the run-loop source when the sensor is released.
private final class SensorObservations {
    let center: NotificationCenter
    var activation: (any NSObjectProtocol)?
    var scrollMonitor: Any?
    var observer: AXObserver?
    var registrations: [(element: AXUIElement, name: String, window: Bool)] = []

    init(center: NotificationCenter) { self.center = center }

    func removeWindow() {
        remove(registrations.filter(\.window))
        registrations.removeAll { $0.window }
    }

    func removeAX() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            remove(registrations)
        }
        registrations = []
        observer = nil
    }

    private func remove(_ entries: [(element: AXUIElement, name: String, window: Bool)]) {
        guard let observer else { return }
        // Retired windows/processes may already have destroyed the registered elements.
        for entry in entries { _ = AXObserverRemoveNotification(observer, entry.element, entry.name as CFString) }
    }

    func stop() {
        if let activation { center.removeObserver(activation) }
        activation = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        removeAX()
    }

    deinit { stop() }
}

@MainActor
public final class ContextSensor {
    public var onSnapshot: (ContextSnapshot, ContextChange) -> Void
    /// Moves and resizes of the focused window.
    public var onWindowFrame: (CGRect) -> Void
    /// Focus moved to another window or app, or the focused window closed.
    public var onWindowChanged: () -> Void
    public var onError: (any Error) -> Void
    public var onScroll: (NSEvent) -> Void = { _ in }

    private let observations = SensorObservations(center: NSWorkspace.shared.notificationCenter)
    private let screenText = ScreenText()
    private var application: NSRunningApplication?
    private var axApplication: AXUIElement?
    private var window: AXUIElement?
    private var windowFrame: CGRect?
    private var axLines: [AXTextLine] = []
    private var textLines: [TextLine] = []
    private var textSource: TextSource = .none
    private var visualTask: Task<[TextLine], any Error>?
    private var ocrLines: [TextLine] = []
    private var pending: Task<Void, Never>?
    private var scrollSettle: Task<Void, Never>?
    private var generation = 0
    private var appChangePending = false
    private var windowChangePending = false
    private var lastCapture = Date.distantPast
    private var lastHost: String?
    private var valueChanges: [AXUIElement: Date] = [:]

    public init(onSnapshot: @escaping (ContextSnapshot, ContextChange) -> Void,
                onWindowFrame: @escaping (CGRect) -> Void, onWindowChanged: @escaping () -> Void,
                onError: @escaping (any Error) -> Void) {
        self.onSnapshot = onSnapshot
        self.onWindowFrame = onWindowFrame
        self.onWindowChanged = onWindowChanged
        self.onError = onError
    }

    public func start() throws {
        stop()
        observations.scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Chromium posts no AX notification for a scroll, so read the newly visible content once it settles
                // (reading during the scroll would stall the marks following it).
                self.scrollSettle?.cancel()
                self.scrollSettle = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(0.8))
                    guard let self, !Task.isCancelled, self.application != nil else { return }
                    self.schedule()
                }
                self.onScroll(event)
            }
        }
        observations.activation = observations.center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, let app = NSRunningApplication(processIdentifier: pid) else { return }
                do { try self.activate(app) } catch { self.report(error) }
            }
        }
        application = nil
        lastHost = nil
        if let app = NSWorkspace.shared.frontmostApplication { try activate(app) }
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        generation += 1
        observations.stop()
        application = nil
        axApplication = nil
        window = nil
        windowFrame = nil
        axLines = []
        textLines = []
        visualTask?.cancel()
        visualTask = nil
        ocrLines = []
    }

    public enum RectKind: String, Sendable { case bounds, estimated, ocr }

    public func markTrack(lineIndex: Int, kind: RectKind?) throws -> MarkTrack? {
        guard textSource == .ax else { return nil }
        let line = axLines[lineIndex]
        var track = try MarkTrack(element: line.element, application: axApplication!, origin: line.origin)
        if kind == .bounds {
            guard let position = try AXAccess.position(line.element) else { return nil }
            track.origin = position
        }
        var element = line.element
        for _ in 0..<3 {
            guard let parent = try AXAccess.element(element, kAXParentAttribute) else { break }
            track.ancestors.append(parent)
            element = parent
        }
        return track
    }

    private var medianHeight: CGFloat {
        let heights = textLines.map(\.rect.height).filter { (8...60).contains($0) }.sorted()
        return heights.isEmpty ? 16 : (heights[(heights.count - 1) / 2] + heights[heights.count / 2]) / 2
    }

    /// Whether the first multiline element can provide a character range's bounds.
    public func boundsProbe() throws -> Bool {
        guard let line = axLines.first(where: { $0.line.rect.height > 1.5 * medianHeight }) else { return true }
        return try AXAccess.bounds(line.element, range: CFRange(location: line.utf16Offset, length: 1)) != nil
    }

    public func visualLines() async throws -> [TextLine] {
        guard ContextPermissions.isGranted(.screenCapture) else { return [] }
        if visualTask == nil {
            let application = application!, frame = windowFrame!
            let title = try AXAccess.value(window!, kAXTitleAttribute) as? String
            visualTask = Task {
                let start = Date()
                let lines = try await screenText.read(pid: application.processIdentifier, title: title, frame: frame)
                if ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1" {
                    FileHandle.standardError.write(Data("[sprite] ocr lines=\(lines.count) \(Int(Date().timeIntervalSince(start) * 1000))ms\n".utf8))
                }
                return lines
            }
        }
        let task = visualTask!
        let generation = generation
        let lines = try await task.value
        try Task.checkCancellation()
        if generation == self.generation { ocrLines = lines }
        return lines
    }

    public func textRect(lineIndex: Int, range: Range<String.Index>) async throws -> (rect: CGRect, kind: RectKind)? {
        let line = textLines[lineIndex]
        if textSource == .ax {
            let axLine = axLines[lineIndex]
            let nsRange = NSRange(range, in: line.text)
            let location = nsRange.location + axLine.utf16Offset
            if let bounds = try AXAccess.bounds(axLine.element, range: CFRange(location: location, length: nsRange.length)),
               let first = try AXAccess.bounds(axLine.element, range: CFRange(location: location,
                    length: String(line.text[range].first!).utf16.count)) {
                if bounds.height <= 1.6 * first.height { return (bounds, .bounds) }
                let characters = Array(line.text[range])
                var low = 1, high = characters.count
                var result = first
                for _ in 0..<6 where low < high {
                    let middle = (low + high + 1) / 2
                    let length = String(characters.prefix(middle)).utf16.count
                    if let prefix = try AXAccess.bounds(axLine.element, range: CFRange(location: location, length: length)),
                       prefix.height <= 1.6 * first.height {
                        low = middle
                        result = prefix
                    } else { high = middle - 1 }
                }
                return (result, .bounds)
            }
        }
        if textSource == .ocr || line.rect.height <= 1.5 * medianHeight {
            return (RuleMatcher.estimatedRect(for: line, range: range), .estimated)
        }
        let visual: [TextLine]
        do { visual = try await visualLines() } catch is CancellationError { throw CancellationError() } catch {
            // ScreenCaptureKit cannot always find the window (e.g. while it is animating); show the remark unframed.
            FileHandle.standardError.write(Data("[sprite] ocr skipped: \(error)\n".utf8))
            return nil
        }
        let lines = visual.filter { $0.rect.intersects(line.rect) }
        let quote = String(line.text[range])
        var prefixes = [quote]
        if quote.count > 6 { prefixes += stride(from: quote.count - 1, through: 6, by: -1).map { String(quote.prefix($0)) } }
        for prefix in prefixes {
            if let hit = SpriteLocator.locate(quote: prefix, lineHint: -1, in: lines) {
                return (RuleMatcher.estimatedRect(for: lines[hit.lineIndex], range: hit.range), .ocr)
            }
        }
        return nil
    }

    public func placementObstacles(in contentFrame: CGRect) -> [CGRect] {
        textLines.filter { $0.rect.intersects(contentFrame) }.flatMap { TextInk.rects(for: $0, medianHeight: medianHeight) }
    }

    public func placementLine(lineIndex: Int, rect: CGRect, kind: RectKind?) -> CGRect {
        let line = kind == .ocr ? ocrLines.first { $0.rect.intersects(rect) }! : textLines[lineIndex]
        let ink = TextInk.rects(for: line, medianHeight: medianHeight).map { $0.insetBy(dx: 4, dy: 1) }
        if ink.count == 1 { return ink[0] }
        if rect.midY >= ink[1].minY { return ink[1] }
        let row = floor((rect.midY - line.rect.minY) / medianHeight)
        return CGRect(x: line.rect.minX, y: line.rect.minY + row * medianHeight,
                      width: line.rect.width, height: medianHeight)
    }

    /// This estimate is used only to place the remark; it is never framed.
    public func unframedRect(lineIndex: Int, range: Range<String.Index>) -> CGRect {
        let line = textLines[lineIndex]
        let row = floor(TextInk.weight(line.text[..<range.lowerBound]) / (line.rect.width / (0.55 * medianHeight)))
        return CGRect(x: line.rect.minX, y: line.rect.minY + row * medianHeight,
                      width: line.rect.width, height: medianHeight)
    }

    public func isSecureFocused() throws -> Bool {
        guard let axApplication else { return false }
        return try AXTextReader.isSecureFocused(axApplication)
    }

    /// Editable text changed recently while the user actually pressed a key.
    public func isTyping(now: Date) throws -> Bool {
        guard CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 2,
              let axApplication, let focused = try AXAccess.element(axApplication, kAXFocusedUIElementAttribute),
              let changed = valueChanges[focused], now.timeIntervalSince(changed) < 3 else { return false }
        let role = try AXAccess.value(focused, kAXRoleAttribute) as? String
        if role == kAXTextFieldRole || role == kAXTextAreaRole { return true }
        return try AXAccess.value(focused, "AXEditable") as? Bool == true
    }

    /// A busy app times out (`cannotComplete`); the next notification reads it again.
    private func report(_ error: any Error) {
        if let failure = error as? AXFailure, failure.code == .cannotComplete { return }
        onError(error)
    }

    private func activate(_ app: NSRunningApplication) throws {
        if application?.processIdentifier == app.processIdentifier { return }
        pending?.cancel()
        generation += 1
        observations.removeAX()
        application = nil
        axApplication = nil
        window = nil
        windowFrame = nil
        axLines = []
        textLines = []
        visualTask?.cancel()
        visualTask = nil
        ocrLines = []
        valueChanges = [:]
        // Our own windows (settings, onboarding) are never narrated.
        guard app.bundleIdentifier != nil, app.processIdentifier != getpid() else {
            onWindowChanged()
            return
        }
        application = app
        axApplication = AXUIElementCreateApplication(app.processIdentifier)
        var observer: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, element, notification, context in
            MainActor.assumeIsolated {
                let sensor = Unmanaged<ContextSensor>.fromOpaque(context!).takeUnretainedValue()
                do { try sensor.receive(notification as String, element: element) } catch { sensor.report(error) }
            }
        }, &observer)
        guard result == .success else { throw AXFailure(operation: "AXObserverCreate", code: result) }
        observations.observer = observer!
        try observe(axApplication!, kAXFocusedWindowChangedNotification, window: false)
        try observe(axApplication!, kAXFocusedUIElementChangedNotification, window: false)
        try observe(axApplication!, kAXValueChangedNotification, window: false)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer!), .commonModes)
        if ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[sprite] \(app.bundleIdentifier!) appChanged timestamp=\(Int(Date().timeIntervalSince1970 * 1000))\n".utf8))
        }
        try bindWindow()
        appChangePending = true
        schedule()
    }

    private func observe(_ element: AXUIElement, _ name: String, window: Bool) throws {
        if observations.registrations.contains(where: { $0.name == name && CFEqual($0.element, element) }) { return }
        let result = AXObserverAddNotification(observations.observer!, element, name as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
        switch result {
        case .success: observations.registrations.append((element, name, window))
        case .apiDisabled: throw AXFailure(operation: name, code: result)
        // Apps refuse individual notifications in their own ways; the window is still read without it.
        default: break
        }
    }

    private func bindWindow() throws {
        observations.removeWindow()
        axLines = []
        textLines = []
        visualTask?.cancel()
        visualTask = nil
        ocrLines = []
        window = try AXAccess.element(axApplication!, kAXFocusedWindowAttribute)
        windowFrame = nil
        windowChangePending = true
        if ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[sprite] \(application!.bundleIdentifier!) windowChanged timestamp=\(Int(Date().timeIntervalSince1970 * 1000))\n".utf8))
        }
        onWindowChanged()
        guard let window else { return }
        for name in [kAXTitleChangedNotification, kAXMovedNotification, kAXResizedNotification,
                     kAXValueChangedNotification, kAXUIElementDestroyedNotification] {
            try observe(window, name, window: true)
        }
        windowFrame = try AXAccess.frame(window)
    }

    private func receive(_ name: String, element: AXUIElement) throws {
        if name == kAXValueChangedNotification {
            let now = Date()
            valueChanges = valueChanges.filter { now.timeIntervalSince($0.value) < 3 }
            valueChanges[element] = now
        }
        if name == kAXMovedNotification || name == kAXResizedNotification {
            if let window, let frame = try AXAccess.frame(window) {
                windowFrame = frame
                onWindowFrame(frame)
            }
            schedule()
            return
        }
        if name == kAXFocusedWindowChangedNotification || name == kAXUIElementDestroyedNotification {
            try bindWindow()
        }
        schedule()
    }

    /// Reads the focused window again as if it had just been switched to.
    public func refresh() {
        windowChangePending = true
        schedule()
    }

    /// App and window switches are read after a 150 ms debounce. Content changes are read at most once per 2 s
    /// (a read already scheduled sees the latest content), so constantly changing apps are not re-traversed.
    private func schedule() {
        let switching = appChangePending || windowChangePending
        if switching {
            pending?.cancel()
            generation += 1
        } else if pending != nil {
            return
        }
        let generation = generation
        let delay = switching ? 0.15 : max(0.3, 2 - Date().timeIntervalSince(lastCapture))
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.pending = nil
                self.lastCapture = Date()
                try await self.capture(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.report(error)
            }
        }
    }

    private func capture(generation: Int) async throws {
        guard let application, let axApplication, let window,
              let frame = try AXAccess.frame(window) else { return }
        windowFrame = frame
        let title = try AXAccess.value(window, kAXTitleAttribute) as? String
        let reading = try AXTextReader.read(window: window, app: axApplication,
                                           bundleID: application.bundleIdentifier!, windowFrame: frame)
        // Rebuild value subscriptions because a page or chat can replace its AX children.
        let valueEntries = observations.registrations.filter { $0.window && $0.name == kAXValueChangedNotification && !CFEqual($0.element, window) }
        for entry in valueEntries {
            _ = AXObserverRemoveNotification(observations.observer!, entry.element, entry.name as CFString)
        }
        observations.registrations.removeAll { $0.window && $0.name == kAXValueChangedNotification && !CFEqual($0.element, window) }
        for element in reading.valueElements { try observe(element, kAXValueChangedNotification, window: true) }
        var lines = reading.lines.map(\.line)
        var source: TextSource = lines.isEmpty ? .none : .ax
        if lines.count < 3 && ContextPermissions.isGranted(.screenCapture) {
            lines = try await screenText.read(pid: application.processIdentifier, title: title, frame: frame)
            source = lines.isEmpty ? .none : .ocr
        }
        try Task.checkCancellation()
        guard generation == self.generation else { return }
        let currentFrame = windowFrame!
        let dx = currentFrame.minX - frame.minX, dy = currentFrame.minY - frame.minY
        lines = lines.map { line in
            if source == .ocr {
                let normalized = CGRect(x: (line.rect.minX - frame.minX) / frame.width,
                                        y: 1 - (line.rect.maxY - frame.minY) / frame.height,
                                        width: line.rect.width / frame.width, height: line.rect.height / frame.height)
                return TextLine(text: line.text, rect: TextGeometry.screenRect(normalized, in: currentFrame))
            }
            return TextLine(text: line.text, rect: line.rect.offsetBy(dx: dx, dy: dy), role: line.role)
        }
        let topInset = reading.contentFrame.minY - frame.minY
        let contentFrame = CGRect(x: currentFrame.minX, y: currentFrame.minY + min(topInset, currentFrame.height),
                                  width: currentFrame.width, height: max(0, currentFrame.height - topInset))
        let host = reading.url.flatMap { value -> String? in
            let url = value.contains("://") ? value : "https://" + value
            guard var host = URL(string: url)?.host?.lowercased() else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
        let change = ContextChange(appChanged: appChangePending, windowChanged: windowChangePending, hostChanged: host != lastHost)
        if textLines != lines || textSource != source {
            visualTask?.cancel()
            visualTask = nil
            ocrLines = []
        }
        textLines = lines
        textSource = source
        axLines = source == .ax ? reading.lines.enumerated().map { index, line in
            AXTextLine(line: lines[index], element: line.element, utf16Offset: line.utf16Offset,
                       origin: CGPoint(x: line.origin.x + dx, y: line.origin.y + dy))
        } : []
        appChangePending = false
        windowChangePending = false
        lastHost = host
        let screenIndex = Self.screenIndex(for: currentFrame)
        let snapshot = ContextSnapshot(bundleId: application.bundleIdentifier!, appName: application.localizedName ?? "",
                                       pid: application.processIdentifier, windowTitle: title, windowFrame: currentFrame,
                                       contentFrame: contentFrame, screenIndex: screenIndex, url: reading.url, host: host,
                                       textLines: lines, textSource: source,
                                       sensitiveRects: reading.sensitiveRects.map { $0.offsetBy(dx: dx, dy: dy) },
                                       secureFocused: reading.secureFocused, fullScreen: reading.fullScreen, capturedAt: Date())
        onSnapshot(snapshot, change)
    }

    private static func screenIndex(for window: CGRect) -> Int {
        let screens = NSScreen.screens
        let top = screens[0].frame.maxY
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.firstIndex {
            CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height).contains(center)
        } ?? 0
    }
}
