import AppKit
import NarratorCore
import NarratorMac

// Cycles 5 shapes × 4 themes on the main screen: one app-level bubble in the top-right of a pretend
// window, plus one anchored bubble with a highlight box. Development only; not part of the app bundle.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let primaryHeight = NSScreen.screens[0].frame.height
let visible = NSScreen.main!.visibleFrame
let fakeWindow = WindowGeometry(frame: CGRect(
    x: visible.minX + 80,
    y: primaryHeight - visible.maxY + 60,
    width: visible.width - 160,
    height: visible.height - 120))
let hitText = CGRect(x: fakeWindow.frame.minX + 140, y: fakeWindow.frame.minY + 320, width: 44, height: 20)

var style = BubbleStyle()
style.dwell = .seconds(2)
let controller = OverlayController(style: style)
BubbleFonts.requestDownload(choice: .persona, persona: .sharp)
BubbleFonts.requestDownload(choice: .persona, persona: .chuuni)

let shapes = BubbleShape.allCases
let themes = ColorTheme.allCases
let animations = BubbleAnimation.allCases
var step = 0

Task { @MainActor in
    while true {
        let shape = shapes[step % shapes.count]
        let theme = themes[(step / shapes.count) % themes.count]
        controller.style.shape = shape
        controller.style.theme = theme
        controller.style.animation = animations[step % animations.count]
        controller.show([
            Narration(id: "app-\(step)", quipID: "又要上班了！", ruleID: "builtin.app.dingtalk", sequence: step,
                      text: "又要上班了！\(shape.rawValue) · \(theme.rawValue)", emoji: ["😩", "☕"], language: "zh", persona: .sharp,
                      anchor: nil, windowID: 1, window: fakeWindow),
            Narration(id: "anchor-\(step)", quipID: "Pig Boss incoming", ruleID: "person.boss", sequence: step,
                      text: "Pig Boss incoming. Look busy.", emoji: ["🐷"], language: "en", persona: .chuuni,
                      anchor: hitText, windowID: 1, window: fakeWindow),
        ])
        step += 1
        try await Task.sleep(for: .seconds(3.2))
    }
}

app.run()
