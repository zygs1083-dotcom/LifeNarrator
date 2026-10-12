import AppKit
import NarratorMac
import SwiftUI

@main
struct LifeNarratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: AppStore

    init() {
        do {
            let value = try AppStore()
            _store = StateObject(wrappedValue: value)
            delegate.store = value
        }
        catch {
            let alert = NSAlert()
            alert.messageText = AppLocalization.string("error", language: .system)
            alert.informativeText = String(describing: error)
            alert.runModal()
            fatalError(String(describing: error))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(systemName: "text.bubble")
                .renderingMode(store.settings.paused ? .original : .template)
                .foregroundStyle(store.settings.paused ? .gray : .primary)
                .accessibilityLabel(store.text(store.settings.paused ? "paused" : "app.name"))
        }
        Settings { AppSettingsView(store: store) }
    }
}

private struct MenuContent: View {
    @ObservedObject var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(store.text(store.settings.paused ? "resume" : "pause")) { store.settings.paused.toggle() }
        Button(store.text("input.open")) { store.showInput() }
        Divider()
        Button(store.text("settings")) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button(store.text("quit")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")

    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore!
    func applicationDidFinishLaunching(_ notification: Notification) { store.start() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .downloading = store.downloader.state {
            Task {
                do {
                    try await store.downloader.pause()
                    sender.reply(toApplicationShouldTerminate: true)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = store.text("error")
                    alert.informativeText = String(describing: error)
                    alert.runModal()
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
