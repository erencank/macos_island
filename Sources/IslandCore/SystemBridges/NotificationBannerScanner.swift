import AppKit
import ApplicationServices

/// Reads Notification Center banners through Accessibility and publishes them app-agnostically.
/// An `AXObserver` triggers immediate scans; a slow timer is the fallback when the observer misses events.
@MainActor
public final class NotificationBannerScanner {
    public var onBannersChanged: (([RawBanner]) -> Void)?

    private static let notificationCenterBundleID = "com.apple.notificationcenterui"
    private static let bannerSubroles: Set<String> = ["AXNotificationCenterAlert", "AXNotificationCenterBanner"]
    private static let observedNotifications = [
        kAXWindowCreatedNotification,
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification
    ]
    private static let maxTreeDepth = 12
    private static let messagingTimeoutSeconds: Float = 0.25

    private var fallbackTimer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var lastKeys: [String] = []

    public init() {}

    public func start() {
        stop()
        guard AXIsProcessTrusted() else {
            IslandLogger.permissions.info("Notification scanner waiting for Accessibility permission")
            scheduleFallbackTimer()
            return
        }
        scheduleFallbackTimer()
        scan()
    }

    public func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        removeObserver()
        NotificationWindowHider.shared.restoreIfNeeded()
        lastKeys = []
    }

    /// Dumps the whole Notification Center AX tree for diagnosing app-specific banner layouts.
    public func dumpAccessibilityTree() -> String {
        guard AXIsProcessTrusted() else { return "Accessibility permission not granted" }
        guard let app = Self.notificationCenterApp() else { return "Notification Center is not running" }
        var lines: [String] = []
        Self.describe(AXUIElementCreateApplication(app.processIdentifier), depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    fileprivate func scan() {
        guard AXIsProcessTrusted(), let app = Self.notificationCenterApp() else { return }
        registerObserverIfNeeded(for: app.processIdentifier)

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeoutSeconds)
        var banners: [RawBanner] = []
        Self.collectBanners(from: appElement, enclosingWindow: nil, depth: 0, into: &banners)

        if banners.isEmpty { NotificationWindowHider.shared.restoreIfNeeded() }

        let keys = banners.map(\.key)
        guard keys != lastKeys else { return }
        lastKeys = keys
        onBannersChanged?(banners)
    }

    private func scheduleFallbackTimer() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    // MARK: - Observer

    private func registerObserverIfNeeded(for pid: pid_t) {
        guard observedPID != pid else { return }
        removeObserver()

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let scanner = Unmanaged<NotificationBannerScanner>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { scanner.scan() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            IslandLogger.system.error("Notification scanner could not create AXObserver")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        for name in Self.observedNotifications {
            AXObserverAddNotification(created, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedPID = pid
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = nil
    }

    // MARK: - Tree traversal

    private static func notificationCenterApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == notificationCenterBundleID }
    }

    private static func collectBanners(
        from element: AXUIElement,
        enclosingWindow: AXUIElement?,
        depth: Int,
        into banners: inout [RawBanner]
    ) {
        guard depth <= maxTreeDepth else { return }

        // Notification Center exposes the frontmost app's entire menu bar; walking it takes seconds.
        let role = string(element, kAXRoleAttribute)
        if role == kAXMenuBarRole { return }
        let currentWindow = role == kAXWindowRole ? element : enclosingWindow

        if let currentWindow, isSidebarWindow(currentWindow) {
            return
        }
        if isSidebarWindow(element) {
            return
        }

        if bannerSubroles.contains(string(element, kAXSubroleAttribute) ?? "") {
            var texts: [String] = []
            var buttons: [BannerButton] = []
            gatherContent(from: element, depth: 0, texts: &texts, buttons: &buttons)
            banners.append(
                RawBanner(
                    texts: texts,
                    buttons: buttons,
                    pressBanner: { press(element) },
                    hideBanner: { hide(banner: element, in: currentWindow) }
                )
            )
            return
        }

        for child in children(of: element) {
            collectBanners(from: child, enclosingWindow: currentWindow, depth: depth + 1, into: &banners)
        }
    }

    private static func gatherContent(
        from element: AXUIElement,
        depth: Int,
        texts: inout [String],
        buttons: inout [BannerButton]
    ) {
        guard depth <= maxTreeDepth else { return }

        let role = string(element, kAXRoleAttribute) ?? ""
        let title = string(element, kAXTitleAttribute) ?? ""
        let value = string(element, kAXValueAttribute) ?? ""
        let description = string(element, kAXDescriptionAttribute) ?? ""

        for candidate in [title, value, description] where !candidate.isEmpty && !texts.contains(candidate) {
            texts.append(candidate)
        }

        if role == kAXButtonRole || role == kAXMenuButtonRole {
            let label = [title, description, value].first { !$0.isEmpty } ?? ""
            if !label.isEmpty {
                buttons.append(BannerButton(title: label, press: { press(element) }))
            }
        }

        for child in children(of: element) {
            gatherContent(from: child, depth: depth + 1, texts: &texts, buttons: &buttons)
        }
    }

    private static func describe(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth <= maxTreeDepth else { return }
        if string(element, kAXRoleAttribute) == kAXMenuBarRole { return }
        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        let fields: [(String, String)] = [
            ("role", string(element, kAXRoleAttribute) ?? ""),
            ("subrole", string(element, kAXSubroleAttribute) ?? ""),
            ("title", string(element, kAXTitleAttribute) ?? ""),
            ("value", string(element, kAXValueAttribute) ?? ""),
            ("desc", string(element, kAXDescriptionAttribute) ?? ""),
            ("actions", ((actionNames as? [String]) ?? []).joined(separator: ","))
        ]
        let rendered = fields.filter { !$0.1.isEmpty }.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
        lines.append(String(repeating: "  ", count: depth) + rendered)
        for child in children(of: element) {
            describe(child, depth: depth + 1, into: &lines)
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else {
            return []
        }
        return (ref as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func isSidebarWindow(_ window: AXUIElement) -> Bool {
        if let title = string(window, kAXTitleAttribute),
           title.localizedCaseInsensitiveContains("Notification Cent") ||
           title.localizedCaseInsensitiveContains("Berichten") {
            return true
        }
        if let id = string(window, "AXIdentifier"),
           id.localizedCaseInsensitiveContains("NotificationCenter") {
            return true
        }
        if let size = size(of: window), size.height > 300 {
            return true
        }
        return false
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Banners are only hideable through their enclosing window; the banner element itself ignores moves.
    private static func hide(banner: AXUIElement, in window: AXUIElement?) {
        guard let window else {
            IslandLogger.system.error("Notification banner has no enclosing window to hide")
            return
        }
        MainActor.assumeIsolated { NotificationWindowHider.shared.hide(window) }
    }

    private static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}
