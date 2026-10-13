import AppKit
import NarratorCore
import SwiftUI
import XCTest
@testable import NarratorMac

@MainActor
final class UISnapshotTests: XCTestCase {
    func testSettingsPagesInLightAndDark() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? ".build/snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", dataDirectory.path, 1)
        defer {
            if let previousDirectory { setenv("LIFENARRATOR_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
        }
        defer { try! FileManager.default.removeItem(at: dataDirectory) }
        var settings = AppSettings()
        settings.language = .zhHans
        settings.provider = .builtin
        try AppDataDirectory().saveSettings(settings)
        let store = try AppStore()
        for tab in SettingsTab.allCases {
            for dark in [false, true] {
                let view = AppSettingsView(store: store, tab: tab)
                let png = try render(view, dark: dark)
                let name = tab == .sprite ? "sprite" : tab.key
                try png.write(to: directory.appendingPathComponent("ui-settings-\(name)-\(dark ? "dark" : "light").png"))
                if [.sprite, .appearance, .general].contains(tab) {
                    let scrolled = try render(view, dark: dark, scrollToBottom: true)
                    try scrolled.write(to: directory.appendingPathComponent("ui-settings-\(name)-scrolled-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func render<V: View>(_ view: V, dark: Bool, scrollToBottom: Bool = false) throws -> Data {
        let bounds = NSRect(x: 0, y: 0, width: 780, height: 580)
        let window = SnapshotWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = bounds
        window.contentView = hosting
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        if scrollToBottom {
            let scroll = try XCTUnwrap(scrollView(in: hosting))
            let document = try XCTUnwrap(scroll.documentView)
            let y = document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
        }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        let first = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 20, y: bitmap.pixelsHigh / 20))
        var hasDifferentColor = false
        for x in 0..<10 {
            for y in 0..<10 {
                let color = try XCTUnwrap(bitmap.colorAt(x: (2 * x + 1) * bitmap.pixelsWide / 20,
                                                       y: (2 * y + 1) * bitmap.pixelsHigh / 20))
                if color != first { hasDifferentColor = true }
            }
        }
        XCTAssertTrue(hasDifferentColor, "UI snapshot must not be a single color")
        return png
    }
}

@MainActor
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
