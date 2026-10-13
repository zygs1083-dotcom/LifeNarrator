import AppKit
import ApplicationServices
import NarratorCore
import QuartzCore
import SwiftUI

public struct MarkTrack {
    let element: AXUIElement
    let application: AXUIElement
    var ancestors: [AXUIElement] = []
    var origin: CGPoint
    var lastHitTest = Date.distantPast

    init(element: AXUIElement, application: AXUIElement, origin: CGPoint) throws {
        for target in [element, application] {
            let result = AXUIElementSetMessagingTimeout(target, 0.1)
            guard result == .success else { throw AXFailure(operation: "AXUIElementSetMessagingTimeout", code: result) }
        }
        self.element = element
        self.application = application
        self.origin = origin
    }
}

/// A bubble on one screen's panel; all rects are in that panel's top-left-origin coordinates.
struct PlacedBubble: Identifiable {
    let id: String
    let windowID: CGWindowID
    let order: Int
    var window: WindowGeometry
    /// Expanded highlight box; nil for an app-level bubble.
    var highlight: CGRect?
    var framed: Bool
    var line: CGRect?
    var obstacles: [CGRect]
    var connector: Bool
    var outside: Bool
    var appearance: BubbleAppearance
    var frame: CGRect
    var track: MarkTrack?
    var leaving = false
    var side: AnchorSide?
    let groupIndex: Int?
    let transition: AnyTransition
    let decorDelay: Double
    let reduceMotion: Bool

    var decor: AnchorDecor? {
        guard framed || outside, let highlight, let side else { return nil }
        return AnchorDecor(highlight: highlight, bubbleFrame: frame, side: side, shape: appearance.shape,
                           size: appearance.size, group: appearance.group, connector: connector, outside: outside, framed: framed)
    }
}

@Observable
@MainActor
final class OverlayModel {
    var bubbles: [PlacedBubble] = []
}

struct OverlayRootView: View {
    let model: OverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.bubbles) { bubble in
                if let decor = bubble.decor {
                    SpriteDecorEntrance(decor: decor, delay: bubble.decorDelay, reduceMotion: bubble.reduceMotion)
                        .transition(bubble.leaving ? .identity : BubbleTransitions.decor())
                }
                BubbleBodyView(appearance: bubble.appearance)
                    .position(x: bubble.frame.midX, y: bubble.frame.midY)
                    .transition(bubble.leaving ? .identity : bubble.transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One transparent, click-through panel covering a screen (visual-spec §10).
@MainActor
final class ScreenOverlay {
    let panel: NSPanel
    let model = OverlayModel()
    /// This screen's top-left corner in global top-left-origin coordinates.
    let origin: CGPoint
    /// Screen visibleFrame in panel coordinates.
    let visibleFrame: CGRect

    init(screen: NSScreen, primaryHeight: CGFloat) {
        origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
        let visible = screen.visibleFrame
        visibleFrame = CGRect(x: visible.minX - origin.x, y: primaryHeight - visible.maxY - origin.y, width: visible.width, height: visible.height)

        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayRootView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

@MainActor
public final class OverlayController: NSObject {
    public var style: BubbleStyle
    public var liveliness: Liveliness = .lively

    private var screens: [CGDirectDisplayID: ScreenOverlay] = [:]
    private let baseHue = Double.random(in: 0..<360)
    private var randomIndex = 0
    private var random = SystemRandomNumberGenerator()
    private var recentGroups: [(theme: ColorTheme, index: Int)] = []
    private var order = 0
    private var dismissMonitors: [Any] = []
    private let onError: (any Error) -> Void
    private var displayLink: CADisplayLink?
    private var lastScroll = Date.distantPast
    private var followFrames = 0
    private var followMoved = 0
    private var followRemoved = 0
    private var followHitRemoved = 0
    private var followTime: TimeInterval = 0
    private var scrollLead: ScrollLead?
    private var scrollBundleID: String?
    private var scrollModes: [String: ScrollLead.Mode] = [:]
    private let debug = ProcessInfo.processInfo.environment["LIFENARRATOR_DEBUG"] == "1"

    public init(style: BubbleStyle, onError: @escaping (any Error) -> Void) {
        self.style = style
        self.onError = onError
        super.init()
    }

    private func inkInset(_ appearance: BubbleAppearance) -> CGSize {
        appearance.shape == .text ? CGSize(width: appearance.size.horizontalPadding, height: appearance.size.verticalPadding) : .zero
    }

    nonisolated static func dwellSeconds(_ seconds: TimeInterval, maxOnScreen: Int) -> TimeInterval {
        maxOnScreen > 3 ? max(seconds, 2.5 * Double(maxOnScreen)) : seconds
    }

    var visibleIDs: Set<String> { Set(screens.values.flatMap { $0.model.bubbles.filter { !$0.leaving }.map(\.id) }) }
    private(set) var lastShownColor: Int?
    private(set) var lastPlacement = "corner"

    @discardableResult
    public func show(_ narration: Narration, track: MarkTrack? = nil) -> Bool {
        show(narration, track: track, delay: 0)
    }

    /// Narrations shown together get the §6 stagger of 60ms × k.
    public func show(_ narrations: [Narration]) {
        for (k, narration) in narrations.enumerated() {
            show(narration, track: nil, delay: 0.06 * Double(k))
        }
    }

    public func highlight(id: String) -> CGRect? {
        for overlay in screens.values {
            if let bubble = overlay.model.bubbles.first(where: { $0.id == id && !$0.leaving }) {
                return bubble.highlight?.offsetBy(dx: overlay.origin.x, dy: overlay.origin.y)
            }
        }
        return nil
    }

    public func scrolled(_ event: NSEvent, bundleID: String) {
        if scrollBundleID != nil && scrollBundleID != bundleID { stopFollowing() }
        lastScroll = Date()
        if displayLink == nil {
            followFrames = 0
            followMoved = 0
            followRemoved = 0
            followHitRemoved = 0
            followTime = 0
        }
        var keyDelta: CGPoint?
        if event.type == .keyDown,
           let track = screens.values.flatMap({ $0.model.bubbles }).first(where: { $0.track != nil && !$0.leaving })?.track {
            do {
                keyDelta = try keyboardScrollDelta(event, application: track.application)
            } catch {
                if (error as? AXFailure)?.code != .cannotComplete { onError(error) }
            }
        }
        if event.type == .scrollWheel || keyDelta != nil {
            for overlay in screens.values {
                for bubble in overlay.model.bubbles where bubble.track == nil && bubble.highlight != nil && !bubble.leaving {
                    removeImmediately(bubble.id, from: overlay)
                    followRemoved += 1
                }
            }
        }
        if displayLink == nil {
            guard let overlay = screens.values.first(where: { $0.model.bubbles.contains { $0.track != nil && !$0.leaving } }) else { return }
            var lead = ScrollLead(mode: scrollModes[bundleID] ?? .throttled, time: lastScroll.timeIntervalSinceReferenceDate)
            for screen in screens.values {
                for bubble in screen.model.bubbles where bubble.track != nil && !bubble.leaving {
                    lead.add(bubble.id, windowID: bubble.windowID)
                }
            }
            scrollLead = lead
            scrollBundleID = bundleID
            let link = overlay.panel.contentView!.displayLink(target: self, selector: #selector(followFrame))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
        if event.type == .scrollWheel {
            let point = CGPoint(x: event.locationInWindow.x, y: NSScreen.screens[0].frame.maxY - event.locationInWindow.y)
            let windows = Set(screens.values.flatMap { overlay in
                overlay.model.bubbles.filter {
                    $0.track != nil && !$0.leaving && $0.window.frame.contains(CGPoint(x: point.x - overlay.origin.x, y: point.y - overlay.origin.y))
                }.map(\.windowID)
            })
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : ScrollLead.lineDelta
            let translations = scrollLead!.event(delta: CGPoint(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale),
                windows: windows, time: lastScroll.timeIntervalSinceReferenceDate,
                duration: event.hasPreciseScrollingDeltas ? 0 : ScrollLead.wheelDuration)
            applyTranslations(translations)
        } else if let keyDelta {
            let windows = Set(scrollLead!.marks.values.map(\.windowID))
            let translations = scrollLead!.event(delta: keyDelta, windows: windows,
                time: lastScroll.timeIntervalSinceReferenceDate, duration: ScrollLead.keyDuration)
            applyTranslations(translations)
        }
    }

    private func keyboardScrollDelta(_ event: NSEvent, application: AXUIElement) throws -> CGPoint? {
        let flags = event.modifierFlags
        guard flags.intersection([.command, .control, .option]).isEmpty,
              !flags.contains(.shift) || event.keyCode == 49,
              [125, 126, 121, 116, 49].contains(event.keyCode) else { return nil }
        guard var focused = try AXAccess.element(application, kAXFocusedUIElementAttribute),
              let role = try AXAccess.value(focused, kAXRoleAttribute) as? String,
              ["AXWebArea", "AXGroup", "AXLink", "AXStaticText", "AXHeading", "AXImage"].contains(role) else { return nil }
        let direction: CGFloat = event.keyCode == 126 || event.keyCode == 116 || flags.contains(.shift) ? 1 : -1
        if event.keyCode == 125 || event.keyCode == 126 {
            return CGPoint(x: 0, y: direction * ScrollLead.lineDelta)
        }
        var focusedRole = role
        while focusedRole != "AXWebArea" {
            guard let parent = try AXAccess.element(focused, kAXParentAttribute),
                  let parentRole = try AXAccess.value(parent, kAXRoleAttribute) as? String else { return nil }
            focused = parent
            focusedRole = parentRole
        }
        guard let frame = try AXAccess.frame(focused) else { return nil }
        return CGPoint(x: 0, y: direction * (frame.height - ScrollLead.pageOverlap))
    }

    @objc private func followFrame(_ link: CADisplayLink) {
        let now = Date()
        guard now.timeIntervalSince(lastScroll) < 0.8 else {
            stopFollowing()
            return
        }
        applyTranslations(scrollLead!.advance(time: now.timeIntervalSinceReferenceDate))
        follow()
    }

    public func follow() {
        let start = Date()
        let looping = displayLink != nil
        if looping { followFrames += 1 }
        let tracked = screens.values.flatMap { overlay in
            overlay.model.bubbles.indices
                .filter { overlay.model.bubbles[$0].track != nil && !overlay.model.bubbles[$0].leaving }
                .map { (overlay, $0) }
        }
        guard !tracked.isEmpty else {
            stopFollowing()
            return
        }
        var positions: [String: CGPoint] = [:]
        var deltas: [String: CGPoint] = [:]
        for (overlay, i) in tracked {
            let model = overlay.model
            let bubble = model.bubbles[i]
            let track = bubble.track!
            do {
                guard let position = try AXAccess.position(track.element) else {
                    removeImmediately(bubble.id, from: overlay)
                    if looping { followRemoved += 1 }
                    continue
                }
                positions[bubble.id] = position
                deltas[bubble.id] = CGPoint(x: position.x - track.origin.x, y: position.y - track.origin.y)
            } catch {
                if let failure = error as? AXFailure, failure.code == .cannotComplete { continue }
                onError(error)
            }
        }
        let translations = scrollLead?.follow(deltas: deltas, time: start.timeIntervalSinceReferenceDate)
            ?? deltas.filter { hypot($0.value.x, $0.value.y) >= 0.5 }
        applyTranslations(translations)
        for (overlay, i) in tracked {
            let bubble = overlay.model.bubbles[i]
            guard !bubble.leaving, let delta = deltas[bubble.id] else { continue }
            // A new mark is checked once even if it has not moved: the model may pick text hidden under a sticky header.
            let tested = bubble.track!.lastHitTest != .distantPast
            if hypot(delta.x, delta.y) >= 0.5 { overlay.model.bubbles[i].track!.origin = positions[bubble.id]! }
            else if tested { continue }
            guard start.timeIntervalSince(bubble.track!.lastHitTest) >= 0.1 else { continue }
            overlay.model.bubbles[i].track!.lastHitTest = start
            let lead = scrollLead?.marks[bubble.id]?.lead ?? .zero
            let highlight = bubble.highlight!
            let point = CGPoint(x: highlight.midX + overlay.origin.x - lead.x,
                                y: highlight.midY + overlay.origin.y - lead.y)
            do {
                if try occluded(bubble.track!, at: point) {
                    removeImmediately(bubble.id, from: overlay)
                    if looping {
                        followRemoved += 1
                        followHitRemoved += 1
                    }
                }
            } catch {
                if let failure = error as? AXFailure, failure.code == .cannotComplete { continue }
                onError(error)
            }
        }
        if looping { followTime += Date().timeIntervalSince(start) }
        if screens.values.allSatisfy({ $0.model.bubbles.allSatisfy { $0.track == nil || $0.leaving } }) {
            stopFollowing()
        }
    }

    private func stopFollowing() {
        guard let displayLink else { return }
        displayLink.invalidate()
        self.displayLink = nil
        var lead = scrollLead!
        let mode = lead.classifiedMode ?? lead.mode
        if let classified = lead.classifiedMode { scrollModes[scrollBundleID!] = classified }
        scrollLead = nil
        scrollBundleID = nil
        applyTranslations(lead.end())
        if debug {
            let average = followFrames == 0 ? 0 : followTime * 1000 / Double(followFrames)
            FileHandle.standardError.write(Data("[sprite] follow frames=\(followFrames) moved=\(followMoved) removed=\(followRemoved) hitRemoved=\(followHitRemoved) moves=\(lead.moves) samples=\(lead.samples) mode=\(mode.rawValue) avgMs=\(String(format: "%.2f", average))\n".utf8))
        }
    }

    private func applyTranslations(_ translations: [String: CGPoint]) {
        for overlay in screens.values {
            let model = overlay.model
            for i in model.bubbles.indices {
                let bubble = model.bubbles[i]
                guard !bubble.leaving, let delta = translations[bubble.id], delta != .zero else { continue }
                guard let moved = BubblePlacement.follow(highlight: bubble.highlight!, frame: bubble.frame,
                    line: bubble.line, obstacles: bubble.obstacles, delta: delta,
                    window: bubble.window, visibleFrame: overlay.visibleFrame) else {
                    removeImmediately(bubble.id, from: overlay)
                    followRemoved += 1
                    continue
                }
                model.bubbles[i].highlight = moved.highlight
                model.bubbles[i].frame = moved.frame
                model.bubbles[i].line = moved.line
                model.bubbles[i].obstacles = moved.obstacles
                followMoved += 1
            }
        }
    }

    private func occluded(_ track: MarkTrack, at point: CGPoint) throws -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(track.application, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return false }
        if CFEqual(element, track.element) || track.ancestors.contains(where: { CFEqual($0, element) }) { return false }
        for _ in 0..<3 {
            guard let parent = try AXAccess.element(element, kAXParentAttribute) else { break }
            if CFEqual(parent, track.element) { return false }
            element = parent
        }
        return true
    }

    /// Moves the window's bubbles with it (§6 position follow). Bubbles that no longer fit are dismissed.
    public func windowFrameChanged(_ windowID: CGWindowID, to window: WindowGeometry) {
        for overlay in screens.values {
            let model = overlay.model
            guard let old = model.bubbles.first(where: { $0.windowID == windowID }) else { continue }
            let local = WindowGeometry(frame: overlay.local(window.frame), chromeHeight: window.chromeHeight)
            let dx = local.frame.minX - old.window.frame.minX
            let dy = local.frame.minY - old.window.frame.minY
            for i in model.bubbles.indices where model.bubbles[i].windowID == windowID {
                model.bubbles[i].window = local
                model.bubbles[i].highlight = model.bubbles[i].highlight?.offsetBy(dx: dx, dy: dy)
                model.bubbles[i].line = model.bubbles[i].line?.offsetBy(dx: dx, dy: dy)
                model.bubbles[i].obstacles = model.bubbles[i].obstacles.map { $0.offsetBy(dx: dx, dy: dy) }
                if let origin = model.bubbles[i].track?.origin {
                    model.bubbles[i].track!.origin = CGPoint(x: origin.x + dx, y: origin.y + dy)
                }
            }
            if hypot(dx, dy) <= 40 {
                restack(windowID, on: overlay)
                reanchor(windowID, on: overlay)
            } else {
                withAnimation(.easeInOut(duration: 0.12)) {
                    restack(windowID, on: overlay)
                    reanchor(windowID, on: overlay)
                }
            }
        }
    }

    public func dismiss(windowID: CGWindowID) {
        for overlay in screens.values {
            for bubble in overlay.model.bubbles where bubble.windowID == windowID {
                remove(bubble.id, from: overlay)
            }
        }
    }

    public func dismissAll() {
        for overlay in screens.values {
            for bubble in overlay.model.bubbles {
                remove(bubble.id, from: overlay)
            }
        }
    }

    @discardableResult
    private func show(_ n: Narration, track: MarkTrack?, delay: Double) -> Bool {
        guard let size = BubblePlacement.sizeTier(requested: style.size, window: n.window) else { return false }
        guard let overlay = overlay(for: n.window.frame) else { return false }
        let model = overlay.model
        let window = WindowGeometry(frame: overlay.local(n.window.frame), chromeHeight: n.window.chromeHeight)

        let groupIndex: Int?
        let group: ColorGroup
        if style.theme == .random {
            group = ColorSelection.randomGroup(baseHue: baseHue, index: randomIndex)
            randomIndex += 1
            groupIndex = nil
        } else {
            let occupied = Set(model.bubbles.filter { $0.appearance.theme == style.theme }.compactMap(\.groupIndex))
            let index: Int
            if liveliness == .quiet {
                let hashed = Int((stableHash(n.ruleID) &+ UInt64(n.sequence)) % UInt64(style.theme.palette.count))
                index = occupied.contains(hashed) ? (hashed + 1) % style.theme.palette.count : hashed
            } else {
                index = ColorSelection.spriteGroupIndex(
                    count: style.theme.palette.count, occupied: occupied,
                    recent: recentGroups.filter { $0.theme == style.theme }.map(\.index),
                    hueOf: style.theme == .clear ? { ColorTheme.clearHues[$0] } : nil, using: &random)
            }
            group = style.theme.palette[index]
            groupIndex = index
        }
        let emoji: [String] = switch style.emojiDensity {
        case .none: []
        case .moderate: Array(n.emoji.prefix(1))
        case .many: n.emoji
        }
        var appearance = BubbleAppearance.make(
            shape: style.shape, size: size, theme: style.theme, group: group, effects: style.textEffects,
            font: BubbleFonts.font(choice: style.font, persona: n.persona, language: n.language, size: size.fontSize),
            text: n.text, emoji: emoji, quipID: n.quipID)

        if model.bubbles.count >= style.maxOnScreen {
            remove(model.bubbles.min { $0.order < $1.order }!.id, from: overlay)
        }

        let frame: CGRect
        var side: AnchorSide?
        var highlight: CGRect?
        var corner = WindowCorner.topRight
        var connector = false
        var outside = false
        if let anchor = n.anchor {
            let box = BubblePlacement.spriteFrame(around: overlay.local(anchor))
            let occupied = model.bubbles.flatMap { [$0.frame] + [$0.highlight].compactMap { $0 } }
            let line = n.line.map(overlay.local) ?? box
            let obstacles = n.obstacles.map(overlay.local)
            let narrow = BubbleAppearance.make(
                shape: style.shape, size: .small, theme: style.theme, group: group, effects: style.textEffects,
                font: BubbleFonts.font(choice: style.font, persona: n.persona, language: n.language, size: BubbleSize.small.fontSize),
                text: n.text, emoji: emoji, quipID: n.quipID, maxWidth: 160)
            guard let placement = BubblePlacement.anchoredSprite(size: appearance.outerSize, frame: box,
                line: line, window: window, visibleFrame: overlay.visibleFrame, occupied: occupied,
                obstacles: obstacles, narrowSize: narrow.outerSize, inkInset: inkInset(appearance)) else { return false }
            if placement.narrow { appearance = narrow }
            if placement.covered {
                appearance.shape = .rounded
                appearance.rotation = .zero
                appearance.fillOpacity = 0.92
                appearance.measure(maxWidth: placement.narrow ? 160 : appearance.size.maxWidth)
            }
            frame = CGRect(origin: placement.frame.origin, size: appearance.outerSize)
            side = placement.side
            highlight = box
            connector = placement.connector
            outside = placement.outside
            lastPlacement = Self.place(placement, highlight: box)
            if style.shape == .speech && n.framed && connector && !placement.covered && !placement.outside {
                appearance.setAnchoredTail(frame: frame, highlight: box, side: placement.side)
            }
        } else {
            if style.shape == .speech {
                appearance.tailBelowBody = size.speechTailHeight
            }
            let stack = model.bubbles.filter { $0.windowID == n.windowID && $0.highlight == nil }.sorted { $0.order > $1.order }
            let layout = BubblePlacement.appStack(sizes: [appearance.outerSize] + stack.map(\.appearance.outerSize), window: window, visibleFrame: overlay.visibleFrame)
            guard let first = layout.frames[0] else { return false }
            frame = first
            lastPlacement = "corner"
            corner = layout.corner
            if style.shape == .speech {
                appearance.setAppLevelTail(corner: corner)
            }
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = reduceMotion ? .fade : style.animation
        let textDelay = delay + (highlight == nil || !n.framed ? 0 : 0.12)
        let bubble = PlacedBubble(
            id: n.id, windowID: n.windowID, order: order, window: window, highlight: highlight,
            framed: n.framed, line: n.line.map(overlay.local), obstacles: n.obstacles.map(overlay.local),
            connector: connector, outside: outside, appearance: appearance,
            frame: frame, track: track, side: side, groupIndex: groupIndex,
            transition: BubbleTransitions.bubble(animation, anchor: appearance.scaleAnchor(side: side, corner: corner), slide: slideOffset(frame: frame, window: window.frame), delay: textDelay, reduceMotion: reduceMotion),
            decorDelay: delay, reduceMotion: reduceMotion)
        order += 1
        if liveliness != .quiet, let groupIndex {
            recentGroups = Array((recentGroups + [(style.theme, groupIndex)]).suffix(2))
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            model.bubbles.append(bubble)
            if highlight == nil {
                restack(n.windowID, on: overlay)
            }
        }
        if track != nil { scrollLead?.add(n.id, windowID: n.windowID) }

        switch style.dwell {
        case .seconds(let seconds):
            let duration = Self.dwellSeconds(seconds, maxOnScreen: style.maxOnScreen)
            Task {
                try await Task.sleep(for: .seconds(textDelay + BubbleTransitions.entranceDuration(animation) + duration))
                remove(n.id, from: overlay)
            }
        case .untilDismissed:
            installDismissMonitors()
        }
        lastShownColor = groupIndex
        return true
    }

    /// Re-runs the §8.1 stack for a window's app-level bubbles, newest on top.
    private func restack(_ windowID: CGWindowID, on overlay: ScreenOverlay) {
        let model = overlay.model
        let indices = model.bubbles.indices
            .filter { model.bubbles[$0].windowID == windowID && model.bubbles[$0].highlight == nil }
            .sorted { model.bubbles[$0].order > model.bubbles[$1].order }
        guard let first = indices.first else { return }
        let layout = BubblePlacement.appStack(sizes: indices.map { model.bubbles[$0].appearance.outerSize }, window: model.bubbles[first].window, visibleFrame: overlay.visibleFrame)
        var dropped: [String] = []
        for (i, frame) in zip(indices, layout.frames) {
            if let frame {
                model.bubbles[i].frame = frame
                if model.bubbles[i].appearance.shape == .speech {
                    model.bubbles[i].appearance.setAppLevelTail(corner: layout.corner)
                }
            } else {
                dropped.append(model.bubbles[i].id)
            }
        }
        for id in dropped {
            remove(id, from: overlay)
        }
    }

    /// Re-runs the §8.2 placement for a window's anchored bubbles after it moved.
    private func reanchor(_ windowID: CGWindowID, on overlay: ScreenOverlay) {
        let model = overlay.model
        var dropped: [String] = []
        for i in model.bubbles.indices where model.bubbles[i].windowID == windowID {
            guard let highlight = model.bubbles[i].highlight else { continue }
            let occupied = model.bubbles.indices.filter { $0 != i }.flatMap { [model.bubbles[$0].frame] + [model.bubbles[$0].highlight].compactMap { $0 } }
            var narrow = model.bubbles[i].appearance
            narrow.measure(maxWidth: 160)
            guard let placement = BubblePlacement.anchoredSprite(size: model.bubbles[i].appearance.outerSize,
                frame: highlight, line: model.bubbles[i].line ?? highlight, window: model.bubbles[i].window,
                visibleFrame: overlay.visibleFrame, occupied: occupied, obstacles: model.bubbles[i].obstacles,
                narrowSize: narrow.outerSize, inkInset: inkInset(model.bubbles[i].appearance)) else {
                dropped.append(model.bubbles[i].id)
                continue
            }
            if placement.narrow { model.bubbles[i].appearance = narrow }
            model.bubbles[i].appearance.tail = nil
            model.bubbles[i].frame = placement.frame
            model.bubbles[i].side = placement.side
            model.bubbles[i].connector = placement.connector
            model.bubbles[i].outside = placement.outside
            if placement.covered {
                model.bubbles[i].appearance.shape = .rounded
                model.bubbles[i].appearance.rotation = .zero
                model.bubbles[i].appearance.fillOpacity = 0.92
                model.bubbles[i].appearance.tail = nil
            }
            if model.bubbles[i].appearance.shape == .speech && model.bubbles[i].framed && placement.connector && !placement.outside {
                model.bubbles[i].appearance.setAnchoredTail(frame: placement.frame, highlight: highlight, side: placement.side)
            }
        }
        for id in dropped {
            remove(id, from: overlay)
        }
    }

    private static func place(_ placement: SpritePlacement, highlight: CGRect) -> String {
        if placement.covered { return "covered" }
        if placement.outside { return placement.side == .right ? "outsideRight" : "outsideLeft" }
        switch placement.side {
        case .above: return "above"
        case .below: return "below"
        case .left: return "leftMargin"
        case .right:
            if placement.connector { return "rightMargin" }
            return abs(placement.frame.minX - highlight.maxX - 8) < 1 ? "right" : "lineEnd"
        }
    }

    private func removeImmediately(_ id: String, from overlay: ScreenOverlay) {
        let index = overlay.model.bubbles.firstIndex { $0.id == id }!
        overlay.model.bubbles[index].leaving = true
        scrollLead?.remove(id)
        DispatchQueue.main.async { [self] in
            remove(id, from: overlay)
        }
    }

    private func remove(_ id: String, from overlay: ScreenOverlay) {
        // The dwell timer may fire after an explicit dismiss already removed the bubble.
        guard let bubble = overlay.model.bubbles.first(where: { $0.id == id }) else { return }
        scrollLead?.remove(id)
        withAnimation(.easeInOut(duration: 0.2)) {
            overlay.model.bubbles.removeAll { $0.id == id }
            if bubble.highlight == nil {
                restack(bubble.windowID, on: overlay)
            }
        }
        if screens.values.allSatisfy({ $0.model.bubbles.isEmpty }) {
            removeDismissMonitors()
        }
        if screens.values.allSatisfy({ $0.model.bubbles.allSatisfy { $0.track == nil || $0.leaving } }) {
            stopFollowing()
        }
    }

    /// The panel of the screen showing most of the window; nil when the window is on no screen.
    private func overlay(for windowFrame: CGRect) -> ScreenOverlay? {
        let primaryHeight = NSScreen.screens[0].frame.height
        func flipped(_ screen: NSScreen) -> CGRect {
            CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        func overlapArea(_ screen: NSScreen) -> CGFloat {
            let r = flipped(screen).intersection(windowFrame)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let screen = NSScreen.screens.max(by: { overlapArea($0) < overlapArea($1) }), overlapArea(screen) > 0 else { return nil }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        if let existing = screens[id] {
            return existing
        }
        let overlay = ScreenOverlay(screen: screen, primaryHeight: primaryHeight)
        screens[id] = overlay
        return overlay
    }

    /// §6 slide: 24pt from whichever window edge is nearest to the bubble.
    private func slideOffset(frame: CGRect, window: CGRect) -> CGSize {
        let edges: [(distance: CGFloat, offset: CGSize)] = [
            (frame.minX - window.minX, CGSize(width: -24, height: 0)),
            (window.maxX - frame.maxX, CGSize(width: 24, height: 0)),
            (frame.minY - window.minY, CGSize(width: 0, height: -24)),
            (window.maxY - frame.maxY, CGSize(width: 0, height: 24)),
        ]
        return edges.min { $0.distance < $1.distance }!.offset
    }

    /// Coordinator decision 6: in "until dismissed" mode any key or click anywhere dismisses everything.
    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        dismissMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
                MainActor.assumeIsolated { self.dismissAll() }
            }!,
            NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                MainActor.assumeIsolated { self.dismissAll() }
                return event
            }!,
        ]
    }

    private func removeDismissMonitors() {
        for monitor in dismissMonitors {
            NSEvent.removeMonitor(monitor)
        }
        dismissMonitors = []
    }
}
