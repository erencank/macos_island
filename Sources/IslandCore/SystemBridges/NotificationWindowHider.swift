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
        guard !hiddenWindows.isEmpty, let origin = savedOrigin() else { return }
        for window in hiddenWindows {
            _ = Self.setPosition(of: window, to: origin)
        }
        hiddenWindows = []
    }

    private func savedOrigin() -> CGPoint? {
        if let originalOrigin { return originalOrigin }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: Self.originXKey), y: defaults.double(forKey: Self.originYKey))
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
