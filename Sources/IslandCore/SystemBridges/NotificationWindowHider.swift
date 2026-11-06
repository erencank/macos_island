import AppKit
import ApplicationServices

/// Owns hiding of Notification Center banner windows for the app notification bridge:
/// moves the window offscreen and puts it back at its original origin once no banner remains.
@MainActor
public final class NotificationWindowHider {
    public static let shared = NotificationWindowHider()

    private static let offscreenX: CGFloat = 12000
    private static let offscreenY: CGFloat = -4000
    private static let hiddenThresholdX: CGFloat = 8000
    private static let originXKey = "island.notifications.windowOriginX"
    private static let originYKey = "island.notifications.windowOriginY"

    private var hiddenWindows: [AXUIElement] = []
    private var originalOrigin: CGPoint?

    private init() {}

    public func owns(_ window: AXUIElement) -> Bool {
        hiddenWindows.contains { CFEqual($0, window) }
    }

    public func hide(_ window: AXUIElement) {
        guard !owns(window) else { return }

        if let current = Self.position(of: window), current.x < Self.hiddenThresholdX {
            originalOrigin = current
            UserDefaults.standard.set(Double(current.x), forKey: Self.originXKey)
            UserDefaults.standard.set(Double(current.y), forKey: Self.originYKey)
        }

        guard Self.setPosition(of: window, to: CGPoint(x: Self.offscreenX, y: Self.offscreenY)) else {
            IslandLogger.system.error("Notification window could not be moved offscreen")
            return
        }
        hiddenWindows.append(window)
    }

    public func restoreIfNeeded() {
        guard !hiddenWindows.isEmpty, let origin = savedOrigin() else {
            restoreStrandedNotificationCenterWindows()
            return
        }
        for window in hiddenWindows {
            _ = Self.setPosition(of: window, to: origin)
        }
        hiddenWindows = []
        restoreStrandedNotificationCenterWindows()
    }

    private func restoreStrandedNotificationCenterWindows() {
        guard let ncApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) else { return }

        let axApp = AXUIElementCreateApplication(ncApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for win in windows {
            if let pos = Self.position(of: win), pos.x >= Self.hiddenThresholdX {
                if let size = Self.size(of: win), size.height > 300 {
                    let screenWidth = NSScreen.main?.frame.width ?? 1440
                    _ = Self.setPosition(of: win, to: CGPoint(x: screenWidth - size.width, y: 0))
                } else if let origin = savedOrigin() {
                    _ = Self.setPosition(of: win, to: origin)
                }
            }
        }
    }

    private func savedOrigin() -> CGPoint? {
        if let originalOrigin { return originalOrigin }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: Self.originXKey), y: defaults.double(forKey: Self.originYKey))
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func setPosition(of element: AXUIElement, to point: CGPoint) -> Bool {
        var target = point
        guard let value = AXValueCreate(.cgPoint, &target) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }
}
