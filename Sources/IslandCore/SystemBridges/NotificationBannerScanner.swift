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
            let canReply = detectCanReply(on: element, texts: texts)
            let candidate = RawBanner(
                texts: texts,
                buttons: buttons,
                canReply: canReply,
                pressBanner: { press(element) },
                hideBanner: { NotificationBannerDismisser.hideWindow(currentWindow) },
                beginReply: { beginReply(on: element) },
                sendReply: { text in sendReply(text, on: element) }
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

    // MARK: - Banner Reply Support

    private static let replyKeywords: Set<String> = [
        "reply", "beantwoorden", "répondre", "antworten", "responder", "rispondi"
    ]
    private static let sendKeywords: Set<String> = [
        "send", "verstuur", "envoyer", "senden", "enviar", "invia"
    ]
    private static let showDetailsKeywords: Set<String> = [
        "show details", "details weergeven", "details einblenden",
        "afficher les détails", "ver detalles", "mostra dettagli"
    ]

    private static func detectCanReply(on bannerElement: AXUIElement, texts: [String]) -> Bool {
        let actions = actionNames(of: bannerElement)
        if actions.contains(where: { action in
            let lowered = BannerTextCleaner.trim(action).lowercased()
            return replyKeywords.contains(where: { lowered.contains($0) })
        }) {
            return true
        }
        if findReplyButton(in: bannerElement) != nil {
            return true
        }
        if findTextArea(in: bannerElement) != nil {
            return true
        }
        if actions.contains(where: { action in
            let lowered = BannerTextCleaner.trim(action).lowercased()
            return sendKeywords.contains(where: { lowered.contains($0) })
        }) {
            return true
        }
        let isKnownMessenger = texts.first.map { firstText in
            let lowered = firstText.lowercased()
            return lowered.contains("whatsapp")
        } ?? false
        if isKnownMessenger && actions.contains(where: { action in
            let lowered = BannerTextCleaner.trim(action).lowercased()
            return showDetailsKeywords.contains(where: { lowered.contains($0) })
        }) {
            return true
        }
        return false
    }

    private static func findTextArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= maxTreeDepth else { return nil }
        if string(element, kAXRoleAttribute) == (kAXTextAreaRole as String) {
            return element
        }
        for child in children(of: element) {
            if let found = findTextArea(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func findReplyButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= maxTreeDepth else { return nil }
        let role = string(element, kAXRoleAttribute)
        if role == (kAXButtonRole as String) || role == (kAXMenuButtonRole as String) {
            let label = [
                string(element, kAXTitleAttribute),
                string(element, kAXDescriptionAttribute),
                string(element, kAXValueAttribute)
            ].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let trimmed = BannerTextCleaner.trim(label).lowercased()
            if replyKeywords.contains(where: { trimmed.contains($0) }) {
                return element
            }
        }
        for child in children(of: element) {
            if let found = findReplyButton(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func findSendButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= maxTreeDepth else { return nil }
        let role = string(element, kAXRoleAttribute)
        if role == (kAXButtonRole as String) || role == (kAXMenuButtonRole as String) {
            let label = [
                string(element, kAXTitleAttribute),
                string(element, kAXDescriptionAttribute),
                string(element, kAXValueAttribute)
            ].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let trimmed = BannerTextCleaner.trim(label).lowercased()
            if sendKeywords.contains(where: { trimmed == $0 || trimmed.contains($0) }) {
                return element
            }
        }
        for child in children(of: element) {
            if let found = findSendButton(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var actionNamesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNamesRef) == .success,
              let names = actionNamesRef as? [String] else {
            return []
        }
        return names
    }

    private static func beginReply(on bannerElement: AXUIElement) -> Bool {
        if let existing = findTextArea(in: bannerElement) {
            AXUIElementSetAttributeValue(existing, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return true
        }

        let actions = actionNames(of: bannerElement)
        if let replyAction = actions.first(where: { action in
            let lowered = BannerTextCleaner.trim(action).lowercased()
            return replyKeywords.contains(where: { lowered.contains($0) })
        }) {
            if AXUIElementPerformAction(bannerElement, replyAction as CFString) == .success {
                return true
            }
        }

        if let replyButton = findReplyButton(in: bannerElement) {
            if press(replyButton) {
                return true
            }
        }

        if let detailsAction = actions.first(where: { action in
            let lowered = BannerTextCleaner.trim(action).lowercased()
            return showDetailsKeywords.contains(where: { lowered.contains($0) })
        }) {
            if AXUIElementPerformAction(bannerElement, detailsAction as CFString) == .success {
                return true
            }
        }

        return false
    }

    private static func sendReply(_ text: String, on bannerElement: AXUIElement) -> Bool {
        var textArea = findTextArea(in: bannerElement)
        if textArea == nil {
            _ = beginReply(on: bannerElement)
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.03)
                textArea = findTextArea(in: bannerElement)
                if textArea != nil { break }
            }
        }

        guard let targetArea = textArea else {
            IslandLogger.system.error("sendReply failed: could not locate AXTextArea in banner")
            return false
        }

        AXUIElementSetAttributeValue(targetArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let setResult = AXUIElementSetAttributeValue(targetArea, kAXValueAttribute as CFString, text as CFTypeRef)
        guard setResult == .success else {
            IslandLogger.system.error("sendReply failed: could not set kAXValueAttribute (error: \(setResult.rawValue))")
            return false
        }

        if let sendButton = findSendButton(in: bannerElement) {
            if press(sendButton) {
                return true
            }
        }

        let actions = actionNames(of: bannerElement)
        if let sendAction = actions.first(where: { action in
            let lowered = BannerTextCleaner.trim(action).lowercased()
            return sendKeywords.contains(where: { lowered.contains($0) })
        }) {
            if AXUIElementPerformAction(bannerElement, sendAction as CFString) == .success {
                return true
            }
        }

        IslandLogger.system.error("sendReply: text was set but send action/button could not be performed")
        return false
    }
}
