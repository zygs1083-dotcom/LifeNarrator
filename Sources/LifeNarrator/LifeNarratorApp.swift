import SwiftUI
import NarratorMac

@main
struct LifeNarratorApp: App {
    var body: some Scene {
        MenuBarExtra("LifeNarrator", systemImage: "text.bubble") {
            Text("LifeNarrator \(NarratorMac.version)")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
