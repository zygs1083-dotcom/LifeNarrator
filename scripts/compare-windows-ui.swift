import AppKit

let mac = URL(fileURLWithPath: CommandLine.arguments[1])
let windows = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3])
let files = try FileManager.default.contentsOfDirectory(at: mac, includingPropertiesForKeys: nil)
    .filter { ["ui-onboarding-", "ui-chat-lv", "ui-menu-lv", "ui-input-"].contains(where: $0.lastPathComponent.hasPrefix) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let pairs = try files.map { source -> (String, NSImage, NSImage) in
    let name = source.lastPathComponent
    let language = name.contains("-en-") ? "en" : "zh"
    let theme = name.contains("-dark") ? "dark" : "light"
    let target = windows.appendingPathComponent("\(language)/\(theme)/\(name)")
    guard let left = NSImage(contentsOf: source), let right = NSImage(contentsOf: target) else {
        throw NSError(domain: "Missing UI snapshot: \(name)", code: 1)
    }
    return (name, left, right)
}
let column: CGFloat = 310
let heights = pairs.map { max($0.1.size.height * (column / $0.1.size.width), $0.2.size.height * (column / $0.2.size.width)) + 30 }
let size = NSSize(width: column * 2, height: heights.reduce(0, +))
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
var top = size.height
for (index, pair) in pairs.enumerated() {
    top -= heights[index]
    let label = "\(pair.0) · Mac / Windows"
    label.draw(at: NSPoint(x: 5, y: top + heights[index] - 22), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
    for (columnIndex, snapshot) in [pair.1, pair.2].enumerated() {
        let scale = column / snapshot.size.width
        let target = NSRect(x: CGFloat(columnIndex) * column, y: top + heights[index] - 30 - snapshot.size.height * scale,
                            width: snapshot.size.width * scale, height: snapshot.size.height * scale)
        snapshot.draw(in: target)
    }
}
image.unlockFocus()
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Compared \(pairs.count) Mac/Windows UI snapshots: \(output.path)")
