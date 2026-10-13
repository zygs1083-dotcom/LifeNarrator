import AppKit
import NarratorCore
import NarratorMac

// Cycles all 12 clear groups on white/dark backgrounds, then every shape × theme.
// Development only; not part of the app bundle.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let primaryHeight = NSScreen.screens[0].frame.height
let visible = NSScreen.main!.visibleFrame
let fakeWindow = WindowGeometry(frame: CGRect(
    x: visible.minX + 80,
    y: primaryHeight - visible.maxY + 60,
    width: visible.width - 160,
    height: visible.height - 120))
let hitText = CGRect(x: fakeWindow.frame.minX + 140, y: fakeWindow.frame.minY + 320, width: 100, height: 20)
let background = NSWindow(contentRect: CGRect(
    x: fakeWindow.frame.minX, y: primaryHeight - fakeWindow.frame.maxY,
    width: fakeWindow.frame.width, height: fakeWindow.frame.height),
    styleMask: [.borderless], backing: .buffered, defer: false)
let targetLabel = NSTextField(labelWithString: "¥1,299.00")
targetLabel.font = .systemFont(ofSize: 16)
targetLabel.frame = CGRect(x: 140, y: fakeWindow.frame.height - 340, width: 100, height: 20)
background.contentView!.addSubview(targetLabel)

var style = BubbleStyle()
style.dwell = .seconds(2)
let controller = OverlayController(style: style)
BubbleFonts.requestDownload(choice: .persona, persona: .sharp)
BubbleFonts.requestDownload(choice: .persona, persona: .chuuni)

let shapes = BubbleShape.allCases
let themes = ColorTheme.allCases
let animations = BubbleAnimation.allCases
var step = 0
let spriteSteps = ColorTheme.clear.palette.count * 2

Task { @MainActor in
    while true {
        let cycleStep = step % (spriteSteps + shapes.count * themes.count)
        if cycleStep < spriteSteps {
            let index = cycleStep / 2
            let dark = cycleStep % 2 == 1
            background.backgroundColor = dark ? NSColor(calibratedWhite: 30.0 / 255, alpha: 1) : .white
            targetLabel.textColor = dark ? .white : .black
            background.orderFrontRegardless()
            controller.dismissAll()
            controller.liveliness = .quiet
            controller.style.shape = .text
            controller.style.theme = .clear
            controller.style.animation = .fade
            let ruleID = "sprite.demo.money"
            let sequence = (index + 12 - Int(stableHash(ruleID) % 12)) % 12
            controller.show(Narration(
                id: "sprite-\(step)", quipID: "又在给钱包放血", ruleID: ruleID, sequence: sequence,
                text: "又在给钱包放血", emoji: ["💸"], language: "zh", persona: .sharp,
                anchor: hitText, windowID: 1, window: fakeWindow))
        } else {
            background.orderOut(nil)
            controller.liveliness = .lively
            let generalStep = cycleStep - spriteSteps
            let shape = shapes[generalStep % shapes.count]
            let theme = themes[(generalStep / shapes.count) % themes.count]
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
        }
        step += 1
        try await Task.sleep(for: .seconds(3.5))
    }
}

app.run()
