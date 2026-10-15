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
            MenuBarView(store: store)
        } label: {
            Image(systemName: "text.bubble")
                .renderingMode(store.settings.paused ? .original : .template)
                .foregroundStyle(store.settings.paused ? .gray : .primary)
                .accessibilityLabel(store.text(store.settings.paused ? "paused" : "app.name"))
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore!
    func applicationDidFinishLaunching(_ notification: Notification) { store.start() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store.showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            if case .downloading = store.downloader.state {
                do {
                    try await store.downloader.pause()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = store.text("error")
                    alert.informativeText = String(describing: error)
                    alert.runModal()
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await store.releaseModel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
