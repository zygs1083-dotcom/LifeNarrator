import Foundation

public enum TextInk {
    public static func weight(_ text: some StringProtocol) -> CGFloat {
        CGFloat(text.reduce(0) { total, character in
            total + (character.unicodeScalars.contains {
                (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
                    || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
                    || (0xFF01...0xFF60).contains($0.value) || (0xFFE0...0xFFE6).contains($0.value)
            } ? 2 : 1)
        })
    }

    public static func rects(for line: TextLine, medianHeight h: CGFloat) -> [CGRect] {
        let rect = line.rect
        let unit = 0.55 * h
        let width = weight(line.text) * unit
        let rows = max(1, Int((rect.height / h).rounded()))
        let ink: [CGRect]
        if rect.height <= 1.5 * h || rows == 1 {
            ink = [CGRect(x: rect.minX, y: rect.minY, width: min(width, rect.width), height: rect.height)]
        } else {
            let precedingHeight = CGFloat(rows - 1) * h
            let lastWidth = min(max(width - CGFloat(rows - 1) * rect.width, unit), rect.width)
            ink = [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: precedingHeight),
                   CGRect(x: rect.minX, y: rect.minY + precedingHeight, width: lastWidth, height: h)]
        }
        return ink.map { $0.insetBy(dx: -4, dy: -1) }
    }
}
