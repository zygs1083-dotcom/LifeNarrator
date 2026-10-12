import ApplicationServices

public enum ContextPermissions {
    public enum Permission { case accessibility, screenCapture }

    public static func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: AXIsProcessTrusted()
        case .screenCapture: CGPreflightScreenCaptureAccess()
        }
    }

    @discardableResult
    public static func request(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility:
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .screenCapture:
            CGRequestScreenCaptureAccess()
        }
    }
}
