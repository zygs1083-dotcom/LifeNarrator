import AppKit
import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var store: AppStore

    public init(store: AppStore) { self.store = store }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                IconChip(symbol: "text.bubble.fill", hue: AppTheme.hue(320))
                Text(store.text("app.name")).font(AppTheme.font(.cardTitle))
                Spacer(minLength: 0)
                Badge(text: status, hue: AppTheme.hue(store.settings.paused ? 42 : 150))
            }
            LabeledContent(store.text("sprite.onDuty")) {
                Toggle(store.text("sprite.onDuty"), isOn: Binding(get: { !store.settings.paused }, set: {
                    store.settings.paused = !$0
                })).labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
            }.frame(minHeight: 28)
            Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
            Button { store.showInput() } label: {
                row("input.open", symbol: "square.and.pencil", shortcut: store.settings.inputShortcut?.description)
            }
            Button { store.showSettings() } label: { row("settings", symbol: "gearshape.fill") }
            Button { NSApplication.shared.terminate(nil) } label: { row("quit", symbol: "power", shortcut: "⌘Q") }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain).toggleStyle(.switch).tint(AppTheme.accent)
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .padding(16).frame(width: 240).background(AppTheme.card)
    }

    var status: String {
        store.settings.paused ? store.text("paused") : "\(store.text("menu.onDuty")) · \(store.text("liveliness.\(store.settings.liveliness.rawValue)"))"
    }

    private func row(_ key: String, symbol: String, shortcut: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(AppTheme.accentDeep)
                .accessibilityHidden(true)
            Text(store.text(key))
            Spacer()
            if let shortcut { Text(verbatim: shortcut).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary) }
        }.frame(height: 28).contentShape(Rectangle())
    }
}
