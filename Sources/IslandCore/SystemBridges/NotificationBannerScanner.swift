import AppKit
import ApplicationServices

/// Reads Notification Center banners through Accessibility and publishes them app-agnostically.
/// An `AXObserver` triggers immediate scans; a fast timer is the fallback when the observer misses events.
@MainActor
public final class NotificationBannerScanner {
    public var onBannersChanged: (([RawBanner]) -> Void)?

    /// When `true`, keeps the Notification Center window parked offscreen while idle so incoming
    /// banners render offscreen from frame 0, and restores it to `(0, 0)` when the tray opens.
    public var shouldParkOffscreen: Bool = false {
        didSet {
            guard oldValue != shouldParkOffscreen, AXIsProcessTrusted() else { return }
            if shouldParkOffscreen {
                scan()
            } else {
                NotificationBannerDismisser.restoreWindowsOnscreen()
            }
        }
    }

    /// Set to `true` by `NotificationBridgePlugin` when a live banner from a non-hidden app is active.
    public var allowOnscreenForCurrentBanner: Bool = false

    private static let notificationCenterBundleID = "com.apple.notificationcenterui"
    private static let bannerSubroles: Set<String> = ["AXNotificationCenterAlert", "AXNotificationCenterBanner"]
    private static let widgetGridRole = "AXOpaqueProviderGroup"
    private static let observedNotifications = [
        kAXWindowCreatedNotification,
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXLayoutChangedNotification,
        kAXApplicationShownNotification,
        kAXFocusedUIElementChangedNotification
    ]
    private static let maxTreeDepth = 12
    private static let messagingTimeoutSeconds: Float = 0.25
    private static let fallbackPollInterval: TimeInterval = 0.04

    private var fallbackTimer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var lastKeys: [String] = []

    public init() {}

    public func start() {
        stop()
        if AXIsProcessTrusted() {
            if shouldParkOffscreen {
                NotificationBannerDismisser.parkWindowsOffscreen()
            } else {
                NotificationBannerDismisser.restoreWindowsOnscreen()
            }
        }
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
        lastKeys = []
        allowOnscreenForCurrentBanner = false
        if AXIsProcessTrusted() {
            NotificationBannerDismisser.restoreWindowsOnscreen()
        }
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
        let scanStart = DispatchTime.now()
        var banners: [RawBanner] = []
        var trayIsOpen = false
        Self.collectBanners(from: appElement, enclosingWindow: nil, depth: 0, into: &banners, trayIsOpen: &trayIsOpen)
        let scanMilliseconds = (DispatchTime.now().uptimeNanoseconds - scanStart.uptimeNanoseconds) / 1_000_000

        let keys = banners.map(\.key)
        if keys != lastKeys {
            lastKeys = keys
            if banners.isEmpty {
                allowOnscreenForCurrentBanner = false
            } else {
                IslandLogger.system.info("Notification scan found banners in \(scanMilliseconds, privacy: .public) ms")
            }
            onBannersChanged?(banners)
        }

        if trayIsOpen || allowOnscreenForCurrentBanner || !shouldParkOffscreen {
            NotificationBannerDismisser.restoreWindowsOnscreen()
        } else {
            NotificationBannerDismisser.parkWindowsOffscreen()
        }
    }

    private func scheduleFallbackTimer() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: Self.fallbackPollInterval, repeats: true) { [weak self] _ in
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

    /// The tray's scroll area also hosts the widget grid; the live banner's scroll area holds only the banner.
    static func isTray(children: [AXUIElement]) -> Bool {
        children.contains { string($0, kAXRoleAttribute) == widgetGridRole }
    }

    private static func collectBanners(
        from element: AXUIElement,
        enclosingWindow: AXUIElement? = nil,
        depth: Int,
        into banners: inout [RawBanner],
        trayIsOpen: inout Bool
    ) {
        guard depth <= maxTreeDepth else { return }

        // Notification Center exposes the frontmost app's entire menu bar; walking it takes seconds.
        let node = attributes(of: element)
        if node.role == kAXMenuBarRole { return }
        let currentWindow = (node.role == kAXWindowRole) ? element : enclosingWindow
        if node.role == kAXScrollAreaRole, isTray(children: node.children) {
            trayIsOpen = true
            return
        }

        if bannerSubroles.contains(node.subrole) {
            var texts: [String] = []
            var buttons: [BannerButton] = []
            gatherContent(from: element, depth: 0, texts: &texts, buttons: &buttons)
            let candidate = RawBanner(
                texts: texts,
                buttons: buttons,
                pressBanner: { press(element) },
                hideBanner: { NotificationBannerDismisser.hideWindow(currentWindow) }
            )
            banners.append(candidate)
            return
        }

        for child in node.children {
            collectBanners(from: child, enclosingWindow: currentWindow, depth: depth + 1, into: &banners, trayIsOpen: &trayIsOpen)
        }
    }

    private static func gatherContent(
        from element: AXUIElement,
        depth: Int,
        texts: inout [String],
        buttons: inout [BannerButton]
    ) {
        guard depth <= maxTreeDepth else { return }

        let node = attributes(of: element)
        for candidate in [node.title, node.value, node.description] where !candidate.isEmpty && !texts.contains(candidate) {
            texts.append(candidate)
        }

        if node.role == kAXButtonRole || node.role == kAXMenuButtonRole {
            let label = [node.title, node.description, node.value].first { !$0.isEmpty } ?? ""
            if !label.isEmpty {
                buttons.append(BannerButton(title: label, press: { press(element) }))
            }
        }

        for child in node.children {
            gatherContent(from: child, depth: depth + 1, texts: &texts, buttons: &buttons)
        }
    }

    private struct NodeAttributes {
        var role = ""
        var subrole = ""
        var title = ""
        var value = ""
        var description = ""
        var children: [AXUIElement] = []
    }

    /// Reads all traversal attributes in one accessibility round trip; each separate call costs an IPC.
    private static func attributes(of element: AXUIElement) -> NodeAttributes {
        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
            kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute
        ] as CFArray
        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
              let values = valuesRef as? [Any], values.count == 6 else {
            return NodeAttributes()
        }
        return NodeAttributes(
            role: values[0] as? String ?? "",
            subrole: values[1] as? String ?? "",
            title: values[2] as? String ?? "",
            value: values[3] as? String ?? "",
            description: values[4] as? String ?? "",
            children: values[5] as? [AXUIElement] ?? []
        )
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

    private static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}
