import AppKit
import ApplicationServices
import NarratorCore

public struct ContextChange: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case appChanged, hostChanged, contentChanged }
    public let appChanged: Bool
    public let hostChanged: Bool
    public var reason: Reason { appChanged ? .appChanged : hostChanged ? .hostChanged : .contentChanged }
}

// The holder also tears down the run-loop source when the sensor is released.
private final class SensorObservations {
    let center: NotificationCenter
    var activation: (any NSObjectProtocol)?
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
        removeAX()
    }

    deinit { stop() }
}

@MainActor
public final class ContextSensor {
    public var onSnapshot: (ContextSnapshot, ContextChange) -> Void
    public var onWindowFrame: (CGRect) -> Void
    public var onError: (any Error) -> Void

    private let observations = SensorObservations(center: NSWorkspace.shared.notificationCenter)
    private let screenText = ScreenText()
    private var application: NSRunningApplication?
    private var axApplication: AXUIElement?
    private var window: AXUIElement?
    private var windowFrame: CGRect?
    private var axLines: [AXTextLine] = []
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var appChangePending = false
    private var lastHost: String?
    private var valueChanges: [AXUIElement: Date] = [:]

    public init(onSnapshot: @escaping (ContextSnapshot, ContextChange) -> Void,
                onWindowFrame: @escaping (CGRect) -> Void, onError: @escaping (any Error) -> Void) {
        self.onSnapshot = onSnapshot
        self.onWindowFrame = onWindowFrame
        self.onError = onError
    }

    public func start() throws {
        stop()
        observations.activation = observations.center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, let app = NSRunningApplication(processIdentifier: pid) else { return }
                do { try self.activate(app) } catch { self.onError(error) }
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
    }

    public func preciseRect(lineIndex: Int, range: Range<String.Index>) throws -> CGRect? {
        guard !axLines.isEmpty else { return nil }
        let line = axLines[lineIndex]
        let nsRange = NSRange(range, in: line.line.text)
        return try AXAccess.bounds(line.element, range: CFRange(location: nsRange.location + line.utf16Offset,
                                                               length: nsRange.length))
    }

    /// The focused element is editable text and changed its value within the last 3 seconds.
    public func isTyping(now: Date) throws -> Bool {
        guard let axApplication, let focused = try AXAccess.element(axApplication, kAXFocusedUIElementAttribute),
              let changed = valueChanges[focused], now.timeIntervalSince(changed) < 3 else { return false }
        let role = try AXAccess.value(focused, kAXRoleAttribute) as? String
        if role == kAXTextFieldRole || role == kAXTextAreaRole { return true }
        return try AXAccess.value(focused, "AXEditable") as? Bool == true
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
        valueChanges = [:]
        guard app.bundleIdentifier != nil else { return }
        application = app
        axApplication = AXUIElementCreateApplication(app.processIdentifier)
        var observer: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, element, notification, context in
            MainActor.assumeIsolated {
                let sensor = Unmanaged<ContextSensor>.fromOpaque(context!).takeUnretainedValue()
                do { try sensor.receive(notification as String, element: element) } catch { sensor.onError(error) }
            }
        }, &observer)
        guard result == .success else { throw AXFailure(operation: "AXObserverCreate", code: result) }
        observations.observer = observer!
        try observe(axApplication!, kAXFocusedWindowChangedNotification, window: false)
        try observe(axApplication!, kAXFocusedUIElementChangedNotification, window: false)
        try observe(axApplication!, kAXValueChangedNotification, window: false)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer!), .commonModes)
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
        case .notificationUnsupported, .notImplemented: break
        default: throw AXFailure(operation: name, code: result)
        }
    }

    private func bindWindow() throws {
        observations.removeWindow()
        axLines = []
        window = try AXAccess.element(axApplication!, kAXFocusedWindowAttribute)
        windowFrame = nil
        guard let window else { return }
        for name in [kAXTitleChangedNotification, kAXMovedNotification, kAXResizedNotification,
                     kAXValueChangedNotification, kAXUIElementDestroyedNotification] {
            try observe(window, name, window: true)
        }
        windowFrame = try AXAccess.frame(window)
        if let windowFrame { onWindowFrame(windowFrame) }
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
            return
        }
        if name == kAXFocusedWindowChangedNotification || name == kAXUIElementDestroyedNotification {
            try bindWindow()
        }
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        generation += 1
        let generation = generation
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                try await self.capture(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.onError(error)
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
            return TextLine(text: line.text, rect: line.rect.offsetBy(dx: dx, dy: dy))
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
        let change = ContextChange(appChanged: appChangePending, hostChanged: host != lastHost)
        axLines = source == .ax ? reading.lines : []
        appChangePending = false
        lastHost = host
        let screenIndex = Self.screenIndex(for: currentFrame)
        let snapshot = ContextSnapshot(bundleId: application.bundleIdentifier!, appName: application.localizedName ?? "",
                                       pid: application.processIdentifier, windowTitle: title, windowFrame: currentFrame,
                                       contentFrame: contentFrame, screenIndex: screenIndex, url: reading.url, host: host,
                                       textLines: lines, textSource: source, capturedAt: Date())
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
