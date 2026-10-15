import AppKit
import NarratorBrain
import NarratorCore
import SwiftUI

@MainActor
final class ChatPanelModel: ObservableObject {
    @Published var turns: [ChatTurn]
    @Published var input = ""
    @Published var sending = false
    @Published var error: String?
    @Published var context = ChatContext()
    @Published var includeScreen = false

    init(turns: [ChatTurn]) { self.turns = turns }

    func send(_ text: String, store: AppStore) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !text.isEmpty else { return }
        sending = true
        error = nil
        let context = context
        let includeScreen = includeScreen
        Task {
            do {
                let turn = try await store.sendChat(text, context: context, includeScreen: includeScreen)
                turns.append(turn)
                turns = Array(turns.suffix(50))
                input = ""
            } catch { self.error = String(describing: error) }
            sending = false
        }
    }
}

@MainActor
final class ChatPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: ChatPanelModel
    private var fade: Task<Void, Never>?

    init(store: AppStore) {
        model = ChatPanelModel(turns: store.chatTurns)
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ChatPanelView(store: store, model: model))
    }

    func show(context: ChatContext, near frame: CGRect?) {
        fade?.cancel()
        panel.alphaValue = 1
        model.context = context
        model.includeScreen = false
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        var point = CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2)
        if let frame {
            point.x = frame.maxX + 12
            if point.x + panel.frame.width > visible.maxX { point.x = frame.minX - panel.frame.width - 12 }
            point.y = frame.maxY - panel.frame.height
        }
        point.x = min(max(point.x, visible.minX), visible.maxX - panel.frame.width)
        point.y = min(max(point.y, visible.minY), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(point)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        fade = Task {
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.18
            await NSAnimationContext.runAnimationGroup { animation in
                animation.duration = duration
                panel.animator().alphaValue = 0
            }
            if Task.isCancelled { return }
            panel.orderOut(nil)
        }
    }
}

private final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ChatPanelView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: ChatPanelModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SpriteAvatar().frame(width: 42, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: displayName).font(AppTheme.font(.cardTitle))
                    Text(store.text("chat.subtitle")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Badge(text: "Lv.\(store.growthState?.level ?? 1)", hue: AppTheme.hue(320))
            }.padding(16)
            Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let narration = model.context.narration {
                            Text(store.text("chat.context") + narration)
                                .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if model.turns.isEmpty {
                            Text(store.text("chat.empty")).font(AppTheme.font(.body)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 28)
                        }
                        ForEach(model.turns) { turn in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verbatim: turn.user).textSelection(.enabled)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(AppTheme.windowBackground, in: RoundedRectangle(cornerRadius: 12))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                reply(turn.reply, id: turn.id.uuidString)
                                if let notice = turn.notice {
                                    Text(verbatim: notice).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }.id(turn.id)
                        }
                        if model.sending {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(store.text("chat.thinking")).foregroundStyle(AppTheme.textSecondary)
                            }.font(AppTheme.font(.caption))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(16)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.sending) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.error {
                    Text(verbatim: error).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.hue(350).text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    quickReplies
                    ScrollView(.horizontal) { quickReplies }.scrollIndicators(.hidden)
                }
                HStack(spacing: 8) {
                    TextField(store.text("chat.placeholder"), text: $model.input, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...3).focused($focused).disabled(model.sending)
                        .accessibilityLabel(store.text("chat.placeholder"))
                        .onSubmit { model.send(model.input, store: store) }
                    Button { model.send(model.input, store: store) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain).foregroundStyle(AppTheme.accentDeep)
                    .disabled(model.sending || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(store.text("chat.send"))
                }
                .padding(10).background(AppTheme.windowBackground, in: RoundedRectangle(cornerRadius: 12))
                Toggle(store.text("chat.screen"), isOn: $model.includeScreen)
                    .toggleStyle(.checkbox).font(AppTheme.font(.caption)).disabled(model.sending || model.context.screen.isEmpty)
                if store.settings.provider == .api && store.settings.generationAPI.isCloud {
                    Text(store.text("chat.privacy")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16)
        }
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .frame(width: 400, height: 520)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.cardStroke, lineWidth: 1))
        .onAppear { focused = true }
        .onChange(of: model.context.narration) { _, _ in focused = true }
    }

    var displayName: String {
        let name = store.settings.spriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.isUnlocked(.spriteName) && !name.isEmpty ? name : store.personas[store.settings.persona].name[store.settings.language.lang]
    }

    private var quickReplies: some View {
        HStack(spacing: 6) {
            ForEach(["again", "quiet", "more", "recall"], id: \.self) { key in
                Button(store.text("chat.quick.\(key)")) { model.send(store.text("chat.quick.\(key)"), store: store) }
                    .buttonStyle(AppTheme.CapsuleButton(filled: false))
            }
        }.fixedSize().font(AppTheme.font(.caption)).disabled(model.sending)
    }

    private func reply(_ text: String, id: String) -> some View {
        let style = store.settings.bubbleStyle
        let group = style.theme == .random ? ColorSelection.randomGroup(baseHue: 320, index: 0) : style.theme.palette[0]
        let font = BubbleFonts.font(choice: style.font, persona: store.settings.persona,
                                    language: store.settings.language.lang.rawValue, size: style.size.fontSize, catalog: store.personas)
        let appearance = BubbleAppearance.make(shape: style.shape, size: style.size, theme: style.theme, group: group,
            effects: style.textEffects, font: font, text: text, emoji: [], quipID: id, maxWidth: 240)
        return BubbleBodyView(appearance: appearance).accessibilityLabel(text)
    }
}

// The speech-bubble face from Assets/AppIcon.svg, in its original 1024-point coordinates.
struct SpriteAvatar: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 392, y: 306)); p.addLine(to: CGPoint(x: 614, y: 306))
                    p.addCurve(to: CGPoint(x: 760, y: 449), control1: CGPoint(x: 707, y: 306), control2: CGPoint(x: 760, y: 360))
                    p.addLine(to: CGPoint(x: 760, y: 539))
                    p.addCurve(to: CGPoint(x: 614, y: 682), control1: CGPoint(x: 760, y: 630), control2: CGPoint(x: 707, y: 682))
                    p.addLine(to: CGPoint(x: 456, y: 682)); p.addLine(to: CGPoint(x: 330, y: 764)); p.addLine(to: CGPoint(x: 350, y: 677))
                    p.addCurve(to: CGPoint(x: 238, y: 539), control1: CGPoint(x: 278, y: 664), control2: CGPoint(x: 238, y: 615))
                    p.addLine(to: CGPoint(x: 238, y: 449))
                    p.addCurve(to: CGPoint(x: 392, y: 306), control1: CGPoint(x: 238, y: 360), control2: CGPoint(x: 294, y: 306))
                    p.closeSubpath()
                }.fill(AppTheme.accentDeep)
                RoundedRectangle(cornerRadius: 33).fill(.white).frame(width: 66, height: 100).position(x: 394, y: 463)
                RoundedRectangle(cornerRadius: 33).fill(.white).frame(width: 66, height: 100).position(x: 591, y: 463)
                Path { p in
                    p.move(to: CGPoint(x: 449, y: 554))
                    p.addCurve(to: CGPoint(x: 536, y: 554), control1: CGPoint(x: 449, y: 531), control2: CGPoint(x: 536, y: 531))
                    p.addLine(to: CGPoint(x: 536, y: 577))
                    p.addCurve(to: CGPoint(x: 449, y: 577), control1: CGPoint(x: 536, y: 637), control2: CGPoint(x: 449, y: 637))
                    p.closeSubpath()
                }.fill(.white)
            }
            .frame(width: 1024, height: 1024)
            .offset(x: -210, y: -230)
            .scaleEffect(geometry.size.width / 620, anchor: .topLeading)
        }
    }
}
