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
        return try attributeValue(value, result: result, name: name)
    }

    static func attributeValue(_ value: CFTypeRef?, result: AXError, name: String) throws -> CFTypeRef? {
        switch result {
        case .success: return value
        // invalidUIElement: the element was destroyed while the window was being read.
        // failure: some apps return the generic error for individual elements; skip them instead of failing the whole read.
        case .attributeUnsupported, .noValue, .notImplemented, .illegalArgument, .invalidUIElement, .failure: return nil
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

    static func position(_ element: AXUIElement) throws -> CGPoint? {
        guard let value = try value(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
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
        case .parameterizedAttributeUnsupported, .attributeUnsupported, .noValue, .notImplemented, .illegalArgument, .invalidUIElement, .failure: return nil
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
    let origin: CGPoint
}

struct AXReading {
    var lines: [AXTextLine]
    var contentFrame: CGRect
    var url: String?
    var valueElements: [AXUIElement]
    var sensitiveRects: [CGRect]
    var secureFocused: Bool
    var fullScreen: Bool
}

enum AXTextReader {
    static let browserIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
    ]

    static func read(window: AXUIElement, app: AXUIElement, bundleID: String,
                     windowFrame: CGRect) throws -> AXReading {
        let isBrowser = browserIDs.contains(bundleID)
        let secureFocused = try isSecureFocused(app)
        let fullScreen = try AXAccess.value(window, "AXFullScreen") as? Bool == true
        var sensitiveRects: [CGRect] = []
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
            if try AXAccess.value(element, "AXHidden") as? Bool == true { continue }
            let frame = try AXAccess.frame(element)
            let visible = frame.map { !$0.isEmpty && $0.intersects(clip) } ?? false
            if role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole {
                if visible { sensitiveRects.append(frame!) }
                continue
            }
            if visible, role == kAXToolbarRole { toolbarBottom = max(toolbarBottom ?? windowFrame.minY, frame!.maxY) }
            if isBrowser, role == "AXWebArea", visible {
                let candidate = try urlString(AXAccess.value(element, kAXURLAttribute))
                    ?? urlString(AXAccess.value(element, kAXDocumentAttribute))
                if webURL == nil { webURL = candidate }
                if let focusedWebArea, CFEqual(element, focusedWebArea) { focusedURL = candidate }
            }
            // Chromium names the omnibox "Address and search bar" / "地址和搜索栏"; its role description is just "text field".
            if isBrowser, role == kAXTextFieldRole, visible,
               let description = try AXAccess.value(element, kAXDescriptionAttribute) as? String,
               description.localizedCaseInsensitiveContains("address") || description.contains("地址") {
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
                        let textRole: TextRole = role == kAXButtonRole ? .button : role == "AXLink" ? .link
                            : [kAXTextFieldRole, kAXTextAreaRole].contains(role) ? .field : .text
                        lines.append(AXTextLine(line: TextLine(text: trimmed.text, rect: textFrame, role: textRole),
                                                element: element, utf16Offset: offset + trimmed.utf16Offset,
                                                origin: frame!.origin))
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
        // A full-screen window hides its title bar, so without a toolbar the content starts at the top.
        let titleBar: CGFloat = fullScreen ? 0 : 52
        let top = min(windowFrame.maxY, toolbarBottom ?? windowFrame.minY + titleBar)
        let contentFrame = CGRect(x: windowFrame.minX, y: top, width: windowFrame.width, height: windowFrame.maxY - top)
        let indices = TextGeometry.sortedIndices(lines.map(\.line))
        return AXReading(lines: indices.map { lines[$0] }, contentFrame: contentFrame,
                         url: isBrowser ? (url ?? focusedURL ?? webURL ?? addressURL) : nil,
                         valueElements: valueElements, sensitiveRects: sensitiveRects,
                         secureFocused: secureFocused, fullScreen: fullScreen)
    }

    static func isSecureFocused(_ app: AXUIElement) throws -> Bool {
        guard let focused = try AXAccess.element(app, kAXFocusedUIElementAttribute) else { return false }
        return try AXAccess.value(focused, kAXRoleAttribute) as? String == "AXSecureTextField"
            || AXAccess.value(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }

    private static func urlString(_ value: CFTypeRef?) -> String? {
        if let value = value as? String { return value }
        return (value as? URL)?.absoluteString
    }
}
