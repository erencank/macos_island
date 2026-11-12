import AppKit
import ApplicationServices

/// Controls Notification Center banner dismissal and offscreen window parking so incoming banners
/// never flash on screen while keeping the Notification Center tray functional when opened.
@MainActor
enum NotificationBannerDismisser {
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"
    private static let dismissActionKeywords = ["close", "clear", "dismiss", "cancel", "sluit"]
    private static let offscreenOrigin = CGPoint(x: 12000, y: -4000)
    private static let strandedThresholdX: CGFloat = 8000

    /// Moves the banner's enclosing window offscreen without invoking the banner's `Close` action,
    /// allowing macOS to naturally transition the banner into the Notification Center tray.
    static func hideWindow(_ window: AXUIElement?) {
        if let window {
            setWindowPosition(window, to: offscreenOrigin)
        } else {
            parkWindowsOffscreen()
        }
    }

    @discardableResult
    static func dismiss(_ banner: AXUIElement, inWindow window: AXUIElement? = nil) -> Bool {
        hideWindow(window)

        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(banner, &namesRef) == .success,
              let names = namesRef as? [String] else {
            IslandLogger.system.error("Notification banner actions unavailable")
            return false
        }

        guard let action = names.first(where: { name in
            dismissActionKeywords.contains { name.lowercased().contains($0) }
        }) else {
            IslandLogger.system.error("Notification banner has no dismiss action: \(names.joined(separator: "|"), privacy: .public)")
            return false
        }

        let succeeded = AXUIElementPerformAction(banner, action as CFString) == .success
        if !succeeded {
            IslandLogger.system.error("Notification banner dismiss action failed")
        }
        return succeeded
    }

    /// Parks all Notification Center windows offscreen so new banners spawn offscreen from frame 0.
    static func parkWindowsOffscreen() {
        for window in notificationCenterWindows() {
            if isOffscreen(window) {
                continue
            }
            setWindowPosition(window, to: offscreenOrigin)
        }
    }

    /// Restores any offscreen Notification Center windows back to `(0, 0)`.
    static func restoreWindowsOnscreen() {
        recoverStrandedWindows(defaultOrigin: .zero)
    }

    /// Repairs windows left offscreen at `x >= 8000`.
    static func recoverStrandedWindows(defaultOrigin: CGPoint = .zero) {
        for window in notificationCenterWindows() {
            guard isOffscreen(window) else { continue }
            setWindowPosition(window, to: defaultOrigin)
        }
    }

    static func isOffscreen(_ window: AXUIElement) -> Bool {
        guard let pos = position(of: window) else { return false }
        return pos.x >= strandedThresholdX
    }

    private static func notificationCenterWindows() -> [AXUIElement] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        }) else { return [] }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }
        return windows
    }

    static func position(of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(of element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    @discardableResult
    static func setWindowPosition(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var target = point
        guard let value = AXValueCreate(.cgPoint, &target) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }
}
