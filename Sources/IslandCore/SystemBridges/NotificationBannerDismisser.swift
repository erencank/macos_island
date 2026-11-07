import AppKit
import ApplicationServices

/// Hides live Notification Center banners by performing their own dismiss action, which leaves the
/// notification in the native tray. Never moves windows: the banner and the tray share one window.
enum NotificationBannerDismisser {
    private static let dismissActionKeywords = ["close", "clear", "dismiss"]
    private static let strandedThresholdX: CGFloat = 8000

    @discardableResult
    static func dismiss(_ banner: AXUIElement) -> Bool {
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
        if !succeeded { IslandLogger.system.error("Notification banner dismiss action failed") }
        return succeeded
    }

    /// Repairs windows left offscreen by earlier versions that hid banners by moving the window.
    static func recoverStrandedWindows() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) else { return }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        var origin = CGPoint.zero
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        for window in windows {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
                  let positionValue = ref else { continue }
            var position = CGPoint.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                  position.x >= strandedThresholdX else { continue }
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }
}
