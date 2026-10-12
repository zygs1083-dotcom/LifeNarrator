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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 210),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
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

private struct RuleInputView: View {
    @ObservedObject var store: AppStore
    let onCompiling: (Bool) -> Void
    @State private var input = ""
    @State private var compiling = false {
        didSet { onCompiling(compiling) }
    }
    @State private var result: Rule?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(store.text("input.title"), systemImage: "text.bubble")
                .font(.headline)
            TextField(store.text("input.placeholder"), text: $input)
                .textFieldStyle(.plain).font(.title2)
                .focused($focused).disabled(compiling)
                .onSubmit(compile)
                .accessibilityLabel(store.text("input.title"))
            Divider()
            if compiling {
                HStack { ProgressView().controlSize(.small); Text(store.text("input.compiling")) }
            } else if let result {
                Label("\(result.label[store.settings.language.lang]) · \(store.text("kind.\(result.kind.rawValue)"))", systemImage: "checkmark.circle.fill")
            } else if let error {
                Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text(store.text("input.hint")).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .onAppear { focused = true }
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
