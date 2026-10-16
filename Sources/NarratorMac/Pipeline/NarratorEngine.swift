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
    private var chatSnapshot: ContextSnapshot?
    private var chatWindowID: UInt32?

    init(store: AppStore) throws {
        self.store = store
        host = MacBrainHost(store: store)
        overlay = OverlayController(style: store.settings.bubbleStyle, onError: { [unowned self] in self.host.reportNow($0) })
        sensor = ContextSensor(onSnapshot: { [unowned self] snapshot, change in
            let id = self.windowID ?? Self.lookupWindowID(pid: snapshot.pid, frame: snapshot.windowFrame)
            if self.windowID != id || self.sensorPort.lines != snapshot.textLines { self.sensorPort.tracks = [:] }
            self.windowID = id
            self.bundleID = snapshot.bundleId
            if snapshot.pid != getpid() { self.chatSnapshot = snapshot; self.chatWindowID = id }
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
        overlay.onChat = { [unowned store] text, frame in store.showChat(narration: text, near: frame) }
        brain.onStateChange = { [unowned store] in store.objectWillChange.send() }
        sensor.onScroll = { [unowned self] event in
            guard let bundleID = self.bundleID else { return }
            self.overlay.scrolled(event, bundleID: bundleID)
        }
    }

    func start() throws {
        configure()
        try sensor.start()
        brain.start()
    }

    func configure() {
        host.keyRejectedShown = false
        overlay.personas = store.personas
        overlay.style = store.settings.bubbleStyle
        overlay.liveliness = store.settings.liveliness
        let settings = store.settings
        let systemOne = settings.systemOne.map { configuration in
            BrainSettings.SystemOne(model: configuration.model, connection: Result {
                (url: try configuration.validatedURL(), key: try KeychainStore.read(account: "systemOne"))
            })
        }
        let available: Bool
        switch settings.provider {
        case .none: available = false
        case .builtin: if case .ready = store.downloader.state { available = true } else { available = false }
        case .api: available = true
        }
        let generator = Result { try store.textGenerator() }
        brain.configure(settings: BrainSettings(liveliness: settings.liveliness, markGap: settings.markGap,
            paused: settings.paused, blacklist: settings.blacklist, persona: settings.persona,
            lang: settings.language.lang, disabledBuiltinIds: settings.disabledBuiltinIds,
            maxOnScreen: settings.bubbleStyle.maxOnScreen, modelAvailable: available,
            systemOne: systemOne, ownProcessID: getpid(), memoryEnabled: settings.memoryEnabled,
            vision: settings.provider == .api && settings.generationAPI.vision),
            content: BrainContent(rules: store.rules, builtin: store.builtin, personas: store.personas),
            generator: generator)
    }

    var chatTurns: [ChatTurn] { brain.chat.turns }

    func chatContext(narration: String?) async throws -> ChatContext {
        try await brain.chatContext(snapshot: chatSnapshot, windowID: chatWindowID, narration: narration)
    }

    func sendChat(_ input: String, context: ChatContext, includeScreen: Bool) async throws -> ChatTurn {
        try await brain.sendChat(input, context: context, includeScreen: includeScreen)
    }

    public var memories: [Memory] { brain.memories }
    public var growthState: GrowthState { brain.growthState }

    @discardableResult
    public func addMemory(kind: Memory.Kind, text: String) throws -> Memory? {
        try brain.addMemory(kind: kind, text: text)
    }

    public func editMemory(id: UUID, kind: Memory.Kind, text: String) throws {
        try brain.editMemory(id: id, kind: kind, text: text)
    }

    public func pinMemory(id: UUID, pinned: Bool) throws { try brain.pinMemory(id: id, pinned: pinned) }
    public func deleteMemory(id: UUID) throws { try brain.deleteMemory(id: id) }
    public func clearMemories() throws { try brain.clearMemories() }
    public func recordGrowth(_ event: GrowthTracker.Event) throws { try brain.recordGrowth(event) }

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
