import AppKit
import ApplicationServices
import NarratorCore

struct AXFailure: Error, CustomStringConvertible {
    let operation: String
    let code: AXError
    var description: String { "AXFailure(operation: \(operation), code: \(code.rawValue))" }
}

enum AXAccess {
    static func value(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch result {
        case .success: return value
        // invalidUIElement: the element was destroyed while the window was being read.
        case .attributeUnsupported, .noValue, .notImplemented, .invalidUIElement: return nil
        default: throw AXFailure(operation: name, code: result)
        }
    }

    static func element(_ source: AXUIElement, _ name: String) throws -> AXUIElement? {
        guard let value = try value(source, name) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AXFailure(operation: name, code: .illegalArgument)
        }
        return (value as! AXUIElement)
    }

    static func frame(_ element: AXUIElement) throws -> CGRect? {
        guard let position = try value(element, kAXPositionAttribute),
              let size = try value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func bounds(_ element: AXUIElement, range: CFRange) throws -> CGRect? {
        var range = range
        let parameter = AXValueCreate(.cfRange, &range)!
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result)
        switch error {
        case .parameterizedAttributeUnsupported, .attributeUnsupported, .noValue, .notImplemented, .illegalArgument, .invalidUIElement: return nil
        case .success: break
        default: throw AXFailure(operation: kAXBoundsForRangeParameterizedAttribute, code: error)
        }
        guard let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) && !rect.isEmpty ? rect : nil
    }
}

struct AXTextLine {
    let line: TextLine
    let element: AXUIElement
    let utf16Offset: Int
}

struct AXReading {
    var lines: [AXTextLine]
    var contentFrame: CGRect
    var url: String?
    var valueElements: [AXUIElement]
}

enum AXTextReader {
    static let browserIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
    ]

    static func read(window: AXUIElement, app: AXUIElement, bundleID: String,
                     windowFrame: CGRect) throws -> AXReading {
        let isBrowser = browserIDs.contains(bundleID)
        var url: String?
        if bundleID == "com.apple.Safari" {
            url = urlString(try AXAccess.value(window, kAXDocumentAttribute))
        }
        var focusedWebArea: AXUIElement?
        if isBrowser, var focused = try AXAccess.element(app, kAXFocusedUIElementAttribute) {
            for _ in 0..<40 {
                if try AXAccess.value(focused, kAXRoleAttribute) as? String == "AXWebArea" {
                    focusedWebArea = focused
                    break
                }
                guard let parent = try AXAccess.element(focused, kAXParentAttribute) else { break }
                focused = parent
            }
        }

        var stack: [(AXUIElement, Int, CGRect)] = [(window, 0, windowFrame)]
        var visited: Set<AXUIElement> = []
        var lines: [AXTextLine] = []
        var valueElements: [AXUIElement] = []
        var toolbarBottom: CGFloat?
        var webURL: String?
        var focusedURL: String?
        var addressURL: String?
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, "AXLink", kAXButtonRole]
        while let (element, depth, clip) = stack.popLast(), visited.count < 4000 {
            guard visited.insert(element).inserted else { continue }
            let role = try AXAccess.value(element, kAXRoleAttribute) as? String
            let subrole = try AXAccess.value(element, kAXSubroleAttribute) as? String
            if role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole { continue }
            if try AXAccess.value(element, "AXHidden") as? Bool == true { continue }
            let frame = try AXAccess.frame(element)
            let visible = frame.map { !$0.isEmpty && $0.intersects(clip) } ?? false
            if visible, role == kAXToolbarRole { toolbarBottom = max(toolbarBottom ?? windowFrame.minY, frame!.maxY) }
            if isBrowser, role == "AXWebArea", visible {
                let candidate = try urlString(AXAccess.value(element, kAXURLAttribute))
                    ?? urlString(AXAccess.value(element, kAXDocumentAttribute))
                if webURL == nil { webURL = candidate }
                if let focusedWebArea, CFEqual(element, focusedWebArea) { focusedURL = candidate }
            }
            if isBrowser, role == kAXTextFieldRole, visible,
               let description = try AXAccess.value(element, kAXRoleDescriptionAttribute) as? String,
               description.localizedCaseInsensitiveContains("address") {
                addressURL = try AXAccess.value(element, kAXValueAttribute) as? String
            }
            if let role, visible, textRoles.contains(role) || ["AXWebArea", "AXCheckBox", kAXScrollAreaRole].contains(role) {
                valueElements.append(element)
            }
            if let role, textRoles.contains(role), visible {
                let title = try AXAccess.value(element, kAXTitleAttribute) as? String
                let text = role == kAXButtonRole ? title : (try AXAccess.value(element, kAXValueAttribute) as? String) ?? title
                if let text {
                    var visibleText = text
                    var offset = 0
                    var textFrame = frame!
                    if role == kAXTextAreaRole,
                       let value = try AXAccess.value(element, kAXVisibleCharacterRangeAttribute),
                       CFGetTypeID(value) == AXValueGetTypeID() {
                        var range = CFRange()
                        if AXValueGetValue(value as! AXValue, .cfRange, &range) {
                            let nsRange = NSRange(location: range.location, length: range.length)
                            guard let stringRange = Range(nsRange, in: text) else {
                                throw AXFailure(operation: kAXVisibleCharacterRangeAttribute, code: .illegalArgument)
                            }
                            visibleText = String(text[stringRange])
                            offset = range.location
                            if let bounds = try AXAccess.bounds(element, range: range) { textFrame = bounds }
                        }
                    }
                    let trimmed = TextGeometry.trimmedText(visibleText)
                    if !trimmed.text.isEmpty {
                        lines.append(AXTextLine(line: TextLine(text: trimmed.text, rect: textFrame),
                                                element: element, utf16Offset: offset + trimmed.utf16Offset))
                    }
                }
            }
            guard depth < 40 else { continue }
            let children = try AXAccess.value(element, kAXVisibleChildrenAttribute) as? [AXUIElement]
                ?? (try AXAccess.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            let childClip = role == kAXScrollAreaRole && frame != nil ? clip.intersection(frame!) : clip
            // Bound queued elements as well as visited ones, including very wide AX trees.
            let remaining = max(0, 4000 - visited.count - stack.count)
            stack.append(contentsOf: children.prefix(remaining).reversed().map { ($0, depth + 1, childClip) })
        }
        let top = min(windowFrame.maxY, toolbarBottom ?? windowFrame.minY + 52)
        let contentFrame = CGRect(x: windowFrame.minX, y: top, width: windowFrame.width, height: windowFrame.maxY - top)
        let indices = TextGeometry.sortedIndices(lines.map(\.line))
        return AXReading(lines: indices.map { lines[$0] }, contentFrame: contentFrame,
                         url: isBrowser ? (url ?? focusedURL ?? webURL ?? addressURL) : nil,
                         valueElements: valueElements)
    }

    private static func urlString(_ value: CFTypeRef?) -> String? {
        if let value = value as? String { return value }
        return (value as? URL)?.absoluteString
    }
}
