import AppKit
import NarratorCore
import SwiftUI

/// A bubble on one screen's panel; all rects are in that panel's top-left-origin coordinates.
struct PlacedBubble: Identifiable {
    let id: String
    let windowID: CGWindowID
    let order: Int
    var window: WindowGeometry
    /// Expanded highlight box; nil for an app-level bubble.
    var highlight: CGRect?
    var appearance: BubbleAppearance
    var frame: CGRect
    var side: AnchorSide?
    let groupIndex: Int?
    let transition: AnyTransition
    let decorTransition: AnyTransition

    var decor: AnchorDecor? {
        guard let highlight, let side else { return nil }
        return AnchorDecor(highlight: highlight, bubbleFrame: frame, side: side, shape: appearance.shape, size: appearance.size, group: appearance.group)
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
                    AnchorDecorView(decor: decor)
                        .transition(bubble.decorTransition)
                }
                BubbleBodyView(appearance: bubble.appearance)
                    .position(x: bubble.frame.midX, y: bubble.frame.midY)
                    .transition(bubble.transition)
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
public final class OverlayController {
    public var style: BubbleStyle

    private var screens: [CGDirectDisplayID: ScreenOverlay] = [:]
    private let baseHue = Double.random(in: 0..<360)
    private var randomIndex = 0
    private var order = 0
    private var dismissMonitors: [Any] = []

    public init(style: BubbleStyle) {
        self.style = style
    }

    public func show(_ narration: Narration) {
        show([narration])
    }

    /// Narrations shown together get the §6 stagger of 60ms × k.
    public func show(_ narrations: [Narration]) {
        for (k, narration) in narrations.enumerated() {
            show(narration, delay: 0.06 * Double(k))
        }
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

    private func show(_ n: Narration, delay: Double) {
        guard let size = BubblePlacement.sizeTier(requested: style.size, window: n.window) else { return }
        guard let overlay = overlay(for: n.window.frame) else { return }
        let model = overlay.model
        let window = WindowGeometry(frame: overlay.local(n.window.frame), chromeHeight: n.window.chromeHeight)

        let groupIndex: Int?
        let group: ColorGroup
        if style.theme == .random {
            group = ColorSelection.randomGroup(baseHue: baseHue, index: randomIndex)
            randomIndex += 1
            groupIndex = nil
        } else {
            let index = ColorSelection.groupIndex(ruleHash: stableHash(n.ruleID), quipSequence: n.sequence, occupied: Set(model.bubbles.compactMap(\.groupIndex)))
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
        if let anchor = n.anchor {
            let box = BubblePlacement.highlightBox(around: overlay.local(anchor))
            guard let placement = BubblePlacement.anchored(size: appearance.outerSize, highlight: box, window: window, visibleFrame: overlay.visibleFrame, occupied: model.bubbles.map(\.frame)) else { return }
            frame = placement.frame
            side = placement.side
            highlight = box
            if style.shape == .speech {
                appearance.setAnchoredTail(frame: frame, highlight: box, side: placement.side)
            }
        } else {
            if style.shape == .speech {
                appearance.tailBelowBody = size.speechTailHeight
            }
            let stack = model.bubbles.filter { $0.windowID == n.windowID && $0.highlight == nil }.sorted { $0.order > $1.order }
            let layout = BubblePlacement.appStack(sizes: [appearance.outerSize] + stack.map(\.appearance.outerSize), window: window, visibleFrame: overlay.visibleFrame)
            guard let first = layout.frames[0] else { return }
            frame = first
            corner = layout.corner
            if style.shape == .speech {
                appearance.setAppLevelTail(corner: corner)
            }
        }

        let animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .fade : style.animation
        let bubble = PlacedBubble(
            id: n.id, windowID: n.windowID, order: order, window: window, highlight: highlight, appearance: appearance,
            frame: frame, side: side, groupIndex: groupIndex,
            transition: BubbleTransitions.bubble(animation, anchor: appearance.scaleAnchor(side: side, corner: corner), slide: slideOffset(frame: frame, window: window.frame), delay: delay),
            decorTransition: BubbleTransitions.decor(animation, delay: delay))
        order += 1
        withAnimation(.easeInOut(duration: 0.2)) {
            model.bubbles.append(bubble)
            if highlight == nil {
                restack(n.windowID, on: overlay)
            }
        }

        switch style.dwell {
        case .seconds(let seconds):
            Task {
                try await Task.sleep(for: .seconds(delay + BubbleTransitions.entranceDuration(animation) + seconds))
                remove(n.id, from: overlay)
            }
        case .untilDismissed:
            installDismissMonitors()
        }
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
            let occupied = model.bubbles.indices.filter { $0 != i }.map { model.bubbles[$0].frame }
            guard let placement = BubblePlacement.anchored(size: model.bubbles[i].appearance.outerSize, highlight: highlight, window: model.bubbles[i].window, visibleFrame: overlay.visibleFrame, occupied: occupied) else {
                dropped.append(model.bubbles[i].id)
                continue
            }
            model.bubbles[i].frame = placement.frame
            model.bubbles[i].side = placement.side
            if model.bubbles[i].appearance.shape == .speech {
                model.bubbles[i].appearance.setAnchoredTail(frame: placement.frame, highlight: highlight, side: placement.side)
            }
        }
        for id in dropped {
            remove(id, from: overlay)
        }
    }

    private func remove(_ id: String, from overlay: ScreenOverlay) {
        // The dwell timer may fire after an explicit dismiss already removed the bubble.
        guard let bubble = overlay.model.bubbles.first(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            overlay.model.bubbles.removeAll { $0.id == id }
            if bubble.highlight == nil {
                restack(bubble.windowID, on: overlay)
            }
        }
        if screens.values.allSatisfy({ $0.model.bubbles.isEmpty }) {
            removeDismissMonitors()
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
