import AppKit
import NarratorCore
import SwiftUI

@MainActor
final class InputPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let store: AppStore
    private var compiling = false

    init(store: AppStore) {
        self.store = store
        panel = RuleInputPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    func show() {
        panel.contentView = NSHostingView(rootView: RuleInputView(store: store) { [weak self] in self?.compiling = $0 })
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.midY - panel.frame.height / 2))
        panel.makeKeyAndOrderFront(nil)
    }

    // Stays up while compiling so a slow model load cannot hide the result or the error.
    func windowDidResignKey(_ notification: Notification) {
        if !compiling { panel.orderOut(nil) }
    }
}

private final class RuleInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct RuleInputView: View {
    @ObservedObject var store: AppStore
    let onCompiling: (Bool) -> Void
    @State private var input = ""
    @State private var compiling = false {
        didSet { onCompiling(compiling) }
    }
    @State private var result: Rule?
    @State private var error: String?
    @FocusState private var focused: Bool
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeading(title: store.text("input.title"), symbol: "text.bubble.fill", hue: AppTheme.hue(320))
            TextField("", text: $input)
                .textFieldStyle(.plain).font(AppTheme.font(.input))
                .overlay(alignment: .leading) {
                    if input.isEmpty {
                        Text(store.text("input.placeholder")).foregroundStyle(AppTheme.textSecondary)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .focused($focused).disabled(compiling)
                .onSubmit(compile)
                .accessibilityLabel(store.text("input.title"))
            Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
            InputStatusRow(state: status, language: store.settings.language)
        }
        .padding(20).frame(width: 600, height: 200, alignment: .topLeading)
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
        .scaleEffect(reduceMotion || appeared ? 1 : 0.96).opacity(appeared ? 1 : 0)
        .onAppear {
            focused = true
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.18)) { appeared = true }
        }
    }

    private var status: InputStatusRow.Status {
        if compiling { return .compiling }
        if let result {
            return .saved(label: result.label[store.settings.language.lang], kind: store.text("kind.\(result.kind.rawValue)"))
        }
        if let error { return .error(error) }
        return .idle
    }

    private func compile() {
        guard !compiling, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        compiling = true
        result = nil
        error = nil
        Task {
            do { result = try await store.compile(input, generator: try store.textGenerator()) }
            catch { self.error = String(describing: error) }
            compiling = false
            focused = true
        }
    }
}

struct InputStatusRow: View {
    enum Status: Equatable {
        case idle, compiling, saved(label: String, kind: String), error(String)
    }
    let state: Status
    let language: InterfaceLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedAppeared = false

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Spacer()
                Text(text("input.hint")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            case .compiling:
                ProgressView().controlSize(.small).tint(AppTheme.accent)
                Text(text("input.compiling")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            case .saved(let label, let kind):
                if reduceMotion {
                    savedIcon
                } else {
                    savedIcon.symbolEffect(.bounce, value: savedAppeared)
                        .onAppear { savedAppeared.toggle() }
                }
                Badge(text: text("input.saved"), hue: AppTheme.hue(150))
                Text(verbatim: "\(label) · \(kind)")
            case .error(let error):
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(AppTheme.hue(350).text)
                    .accessibilityHidden(true)
                Text(verbatim: error).foregroundStyle(AppTheme.hue(350).text).textSelection(.enabled)
            }
        }
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    private var savedIcon: some View {
        Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(AppTheme.hue(150).text)
            .accessibilityHidden(true)
    }
    private func text(_ key: String) -> String { AppLocalization.string(key, language: language) }
}
