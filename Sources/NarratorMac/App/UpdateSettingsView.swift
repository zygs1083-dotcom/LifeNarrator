import NarratorCore
import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updater: Updater
    private let hue = AppTheme.hue(42)

    var body: some View {
        GroupBox {
            LabeledContent(store.text("version"), value: NarratorCore.version)
            Button(store.settings.language.lang == .zh ? "更新公告" : "What is new") { store.showAnnouncement() }
                .buttonStyle(AppTheme.CapsuleButton(hue: hue, filled: false))
            Toggle(store.text("updates.automatic"), isOn: $store.settings.automaticUpdates)
            switch updater.state {
            case .idle: EmptyView()
            case .checking:
                ProgressView(store.text("updates.checking")).controlSize(.small)
            case .upToDate:
                Text(store.text("updates.latest"))
            case .available(let release):
                HStack {
                    Link(String(format: store.text("updates.available"), release.tag), destination: release.pageURL)
                    Spacer()
                    Button(store.text("updates.install")) { Task { await updater.install(release) } }
                        .buttonStyle(AppTheme.CapsuleButton(hue: hue))
                }
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text(String(format: store.text("updates.downloading"), Int(progress * 100)))
                }
            case .failed(let message):
                Text(verbatim: message).textSelection(.enabled)
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Button(store.text("updates.check")) { Task { await updater.check() } }
                .buttonStyle(AppTheme.CapsuleButton(hue: hue, filled: false))
                .disabled(updater.isBusy)
        } label: { CardHeading(title: store.text("updates.title"), symbol: "arrow.down.circle", hue: hue) }
    }
}

struct MenuUpdateRow: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updater: Updater

    var body: some View {
        if case .available(let release) = updater.state {
            Link(destination: release.pageURL) {
                Label(String(format: store.text("updates.available"), release.tag), systemImage: "arrow.down.circle")
                    .foregroundStyle(AppTheme.accentDeep)
            }
        }
    }
}

