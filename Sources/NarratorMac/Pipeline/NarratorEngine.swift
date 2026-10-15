import AppKit
import NarratorCore
import NarratorBrain

@MainActor
public final class NarratorEngine {
    private unowned let store: AppStore
    private var sensor: ContextSensor!
    private var overlay: OverlayController!
    private var sensorPort: MacBrainSensor!
    private var brain: SpriteBrain!
    private let host: MacBrainHost
    private var windowID: CGWindowID?
    private var bundleID: String?

    init(store: AppStore) throws {
        self.store = store
        host = MacBrainHost(store: store)
        overlay = OverlayController(style: store.settings.bubbleStyle, onError: { [unowned self] in self.host.reportNow($0) })
        sensor = ContextSensor(onSnapshot: { [unowned self] snapshot, change in
            let id = self.windowID ?? Self.lookupWindowID(pid: snapshot.pid, frame: snapshot.windowFrame)
            if self.windowID != id || self.sensorPort.lines != snapshot.textLines { self.sensorPort.tracks = [:] }
            self.windowID = id
            self.bundleID = snapshot.bundleId
            self.sensorPort.lines = snapshot.textLines
            self.brain.snapshot(snapshot, windowID: id, change: change)
        }, onWindowFrame: { [unowned self] in self.brain.windowFrameChanged($0) },
           onWindowChanged: { [unowned self] in
            self.windowID = nil
            self.bundleID = nil
            self.sensorPort.tracks = [:]
            self.brain.windowChanged()
        }, onError: { [unowned self] in self.host.reportNow($0) })
        sensorPort = MacBrainSensor(sensor: sensor, host: host)
        brain = try SpriteBrain(sensor: sensorPort, overlay: MacBrainOverlay(overlay: overlay, sensor: sensorPort),
            host: host, saidURL: store.directory.said)
        sensor.onScroll = { [unowned self] event in
            guard let bundleID = self.bundleID else { return }
            self.overlay.scrolled(event, bundleID: bundleID)
        }
    }

    func start() throws {
        try configure()
        try sensor.start()
        brain.start()
    }

    func configure() throws {
        overlay.personas = store.personas
        overlay.style = store.settings.bubbleStyle
        overlay.liveliness = store.settings.liveliness
        let settings = store.settings
        let systemOne = try settings.systemOne.map {
            BrainSettings.SystemOne(url: try $0.validatedURL(), model: $0.model, key: try KeychainStore.read(account: "systemOne"))
        }
        let generator = try store.textGenerator()
        brain.configure(settings: BrainSettings(liveliness: settings.liveliness, markGap: settings.markGap,
            paused: settings.paused, blacklist: settings.blacklist, persona: settings.persona,
            lang: settings.language.lang, disabledBuiltinIds: settings.disabledBuiltinIds,
            maxOnScreen: settings.bubbleStyle.maxOnScreen, modelAvailable: generator != nil,
            systemOne: systemOne, ownProcessID: getpid()),
            content: BrainContent(rules: store.rules, builtin: store.builtin, personas: store.personas),
            generator: generator)
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
