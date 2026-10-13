import AppKit
import NarratorCore
import SwiftUI
import XCTest
@testable import NarratorMac

@MainActor
final class UISnapshotTests: XCTestCase {
    func testSettingsPagesInLightAndDark() throws {
        _ = NSApplication.shared
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
            }
        }
    }

    private func render<V: View>(_ view: V, dark: Bool) throws -> Data {
        let bounds = NSRect(x: 0, y: 0, width: 780, height: 580)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = bounds
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
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
