import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class NotificationBridgePlugin: ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.notifications"
    public let displayName = "App Notifications"
    public let symbolName = "bell.badge.fill"

    @Published public var isEnabled: Bool {
        didSet { syncScannerParking() }
    }
    @Published public var slackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(slackEnabled, forKey: Self.slackKey)
            syncScannerParking()
        }
    }
    @Published public var teamsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(teamsEnabled, forKey: Self.teamsKey)
            syncScannerParking()
        }
    }
    @Published public var outlookEnabled: Bool {
        didSet {
            UserDefaults.standard.set(outlookEnabled, forKey: Self.outlookKey)
            syncScannerParking()
        }
    }
    @Published public var hideSlackBanner: Bool {
        didSet {
            UserDefaults.standard.set(hideSlackBanner, forKey: Self.hideSlackKey)
            syncScannerParking()
        }
    }
    @Published public var hideTeamsBanner: Bool {
        didSet {
            UserDefaults.standard.set(hideTeamsBanner, forKey: Self.hideTeamsKey)
            syncScannerParking()
        }
    }
    @Published public var hideOutlookBanner: Bool {
        didSet {
            UserDefaults.standard.set(hideOutlookBanner, forKey: Self.hideOutlookKey)
            syncScannerParking()
        }
    }
    @Published public var otherAppsEnabled: Bool {
        didSet { UserDefaults.standard.set(otherAppsEnabled, forKey: Self.otherAppsKey) }
    }
    @Published public var messageDuration: Double {
        didSet { UserDefaults.standard.set(messageDuration, forKey: Self.durationKey) }
    }
    @Published public var maxWingWidth: Double {
        didSet {
            UserDefaults.standard.set(maxWingWidth, forKey: Self.maxWingWidthKey)
            if isCalibratingWidth {
                presentWidthCalibrationPreview()
            }
        }
    }
    @Published public private(set) var isCalibratingWidth: Bool = false

    private static let slackKey = "island.notifications.slack"
    private static let teamsKey = "island.notifications.teams"
    private static let outlookKey = "island.notifications.outlook"
    private static let hideSlackKey = "island.notifications.hideBanner.slack"
    private static let hideTeamsKey = "island.notifications.hideBanner.teams"
    private static let hideOutlookKey = "island.notifications.hideBanner.outlook"
    private static let otherAppsKey = "island.notifications.otherApps"
    private static let durationKey = "island.notifications.messageDuration"
    private static let maxWingWidthKey = "island.notifications.maxWingWidth"
    private static let hoverExitDismissDelay: TimeInterval = 1.5
    private static let duplicateWindow: TimeInterval = 3.0
    private static let ignoredAppNames: Set<String> = ["airdrop", "island"]

    private struct ActiveNotification {
        let payloadID: String
        let notification: IslandNotification
        let banner: RawBanner?
    }

    private let scanner = NotificationBannerScanner()
    private let parsers = NotificationParserSet()
    private weak var coordinator: NotchStateCoordinator?
    private var presentedKeys = Set<String>()
    private var recentSignatures: [String: Date] = [:]
    private var active: ActiveNotification?
    private var dismissTask: Task<Void, Never>?
    private var widthCalibrationDismissTask: Task<Void, Never>?
    private var hoverCancellable: AnyCancellable?

    public init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "island.plugin.com.island.plugin.notifications.enabled") as? Bool ?? true
        slackEnabled = defaults.object(forKey: Self.slackKey) as? Bool ?? true
        teamsEnabled = defaults.object(forKey: Self.teamsKey) as? Bool ?? true
        outlookEnabled = defaults.object(forKey: Self.outlookKey) as? Bool ?? true
        hideSlackBanner = defaults.object(forKey: Self.hideSlackKey) as? Bool ?? false
        hideTeamsBanner = defaults.object(forKey: Self.hideTeamsKey) as? Bool ?? false
        hideOutlookBanner = defaults.object(forKey: Self.hideOutlookKey) as? Bool ?? false
        otherAppsEnabled = defaults.object(forKey: Self.otherAppsKey) as? Bool ?? false
        let savedDuration = defaults.object(forKey: Self.durationKey) as? Double ?? 4.0
        messageDuration = max(1.0, min(15.0, savedDuration))
        maxWingWidth = defaults.object(forKey: Self.maxWingWidthKey) as? Double ?? 185.0

        scanner.onBannersChanged = { [weak self] banners in
            self?.handle(banners: banners)
        }
        syncScannerParking()
    }

    private func syncScannerParking() {
        scanner.shouldParkOffscreen = isEnabled && (
            (slackEnabled && hideSlackBanner) ||
            (teamsEnabled && hideTeamsBanner) ||
            (outlookEnabled && hideOutlookBanner)
        )
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        hoverCancellable?.cancel()
        hoverCancellable = coordinator.$isHovering
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering in
                guard let self, !hovering, let kind = self.active?.notification.kind, kind != .incomingCall else { return }
                self.scheduleDismiss(after: Self.hoverExitDismissDelay)
            }
        scanner.start()
    }

    public func stop() {
        scanner.stop()
        dismissTask?.cancel()
        hoverCancellable?.cancel()
        presentedKeys = []
        recentSignatures = [:]
        active = nil
        coordinator?.clearPersistentActivity(pluginID: id)
    }

    /// Writes the current Notification Center AX tree to a temp file and reveals it in Finder.
    public func revealAccessibilityTreeDump() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("island-notification-ax-tree.txt")
        do {
            try scanner.dumpAccessibilityTree().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            IslandLogger.system.error("Notification tree dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Banner handling

    func handle(banners: [RawBanner]) {
        let currentKeys = Set(banners.map(\.key))
        presentedKeys.formIntersection(currentKeys)

        var anyHiddenBanner = false
        var anyVisibleBanner = false

        for banner in banners {
            let parsed = notification(for: banner)
            if let parsed, shouldHideBanner(for: parsed.appName) {
                anyHiddenBanner = true
            } else if !BannerTextCleaner.isTrayItem(banner) {
                anyVisibleBanner = true
            }

            guard !presentedKeys.contains(banner.key) else { continue }
            presentedKeys.insert(banner.key)
            guard let notification = parsed, !isRecentDuplicate(notification) else { continue }
            if shouldHideBanner(for: notification.appName) { banner.hideBanner() }
            present(notification, banner: banner, payloadID: banner.key)
        }

        scanner.allowOnscreenForCurrentBanner = anyVisibleBanner && !anyHiddenBanner

        if let active, active.notification.kind == .incomingCall,
           let banner = active.banner, !currentKeys.contains(banner.key) {
            dismissCurrent()
        }
    }

    /// A tray card re-exposed by hovering carries the same content as the banner shown earlier, so it
    /// must neither be presented again nor dismissed (dismissing it would remove it from the tray).
    private func isRecentDuplicate(_ notification: IslandNotification) -> Bool {
        guard notification.kind != .incomingCall else { return false }
        let now = Date()
        recentSignatures = recentSignatures.filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }
        let signature = [notification.appName, notification.sender, notification.channel ?? "", notification.title ?? "", notification.body]
            .joined(separator: "\u{1F}")
        defer { recentSignatures[signature] = now }
        return recentSignatures[signature] != nil
    }

    private func notification(for banner: RawBanner) -> IslandNotification? {
        if BannerTextCleaner.isTrayItem(banner) {
            return nil
        }
        if let parsed = parsers.parse(banner) {
            return isAppEnabled(parsed.appName) ? parsed : nil
        }
        guard otherAppsEnabled,
              let generic = parsers.parseGeneric(banner),
              !Self.ignoredAppNames.contains(generic.appName.lowercased()) else {
            return nil
        }
        return generic
    }

    private func shouldHideBanner(for appName: String) -> Bool {
        switch appName {
        case SlackNotificationParser.appName: return hideSlackBanner
        case TeamsNotificationParser.appName: return hideTeamsBanner
        case OutlookNotificationParser.appName: return hideOutlookBanner
        default: return false
        }
    }

    private func isAppEnabled(_ appName: String) -> Bool {
        switch appName {
        case SlackNotificationParser.appName: return slackEnabled
        case TeamsNotificationParser.appName: return teamsEnabled
        case OutlookNotificationParser.appName: return outlookEnabled
        default: return false
        }
    }

    // MARK: - Presentation

    private func present(
        _ notification: IslandNotification,
        banner: RawBanner?,
        payloadID: String,
        forcedRightWingWidth: CGFloat? = nil
    ) {
        guard isEnabled, let coordinator else { return }
        if active?.notification.kind == .incomingCall, notification.kind != .incomingCall { return }

        dismissTask?.cancel()
        active = ActiveNotification(payloadID: payloadID, notification: notification, banner: banner)

        let isCall = notification.kind == .incomingCall
        let rightWidth = forcedRightWingWidth ?? (isCall ? 44 : Self.messageWingWidth(for: notification, maxAllowedWidth: maxWingWidth))
        let payload = NotchActivityPayload(
            id: payloadID,
            pluginID: id,
            priority: isCall ? .critical : .high,
            posture: .compactWings,
            wingSizes: NotchWingSizes(leftWidth: 36, rightWidth: rightWidth),
            compactLeadingView: AnyView(NotificationCompactLeadingView(notification: notification)),
            compactTrailingView: AnyView(NotificationCompactTrailingView(notification: notification)),
            expandedView: AnyView(NotificationExpandedCardView(plugin: self, notification: notification)),
            accentColor: isCall ? .green : .white
        )
        coordinator.publishPersistentActivity(payload)

        if !isCall {
            scheduleDismiss(after: messageDuration)
        }
    }

    public static func messageWingWidth(for notification: IslandNotification, maxAllowedWidth: Double = 185.0) -> CGFloat {
        let headlineFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let headlineWidth = (notification.headline as NSString).size(withAttributes: [.font: headlineFont]).width

        if let subtext = notification.subtext, !subtext.isEmpty {
            let subtextFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            let subtextWidth = (subtext as NSString).size(withAttributes: [.font: subtextFont]).width
            let maxTextWidth = max(headlineWidth, subtextWidth)
            let needed = maxTextWidth + 18
            return max(70, min(CGFloat(maxAllowedWidth), ceil(needed)))
        } else {
            let needed = headlineWidth + 18
            return max(56, min(CGFloat(maxAllowedWidth), ceil(needed)))
        }
    }

    public func triggerWidthPreview(isEditing: Bool) {
        widthCalibrationDismissTask?.cancel()
        if isEditing {
            isCalibratingWidth = true
            presentWidthCalibrationPreview()
        } else {
            isCalibratingWidth = false
            widthCalibrationDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self else { return }
                self.dismissCurrent()
            }
        }
    }

    private func presentWidthCalibrationPreview() {
        let widthVal = Int(maxWingWidth.rounded())
        let sample = IslandNotification(
            appName: "Slack",
            kind: .message,
            sender: "Alex Rivera",
            channel: "#acme-team-25",
            body: "Width limit: \(widthVal) px"
        )
        present(sample, banner: nil, payloadID: "width-calibration-\(widthVal)", forcedRightWingWidth: CGFloat(maxWingWidth))
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let coordinator = self.coordinator else { return }
            if coordinator.isHovering || coordinator.posture == .expandedCard { return }
            self.dismissCurrent()
        }
    }

    // MARK: - Actions

    public func openCurrent() {
        guard let active else { return }
        let opened = active.banner?.pressBanner() ?? false
        if !opened { activateApp(named: active.notification.appName) }
        dismissCurrent()
    }

    public func acceptCurrent() {
        guard let active else { return }
        if !pressButton(matching: ["accept", "answer"], in: active) {
            activateApp(named: active.notification.appName)
        }
        dismissCurrent()
    }

    public func declineCurrent() {
        guard let active else { return }
        _ = pressButton(matching: ["decline", "reject"], in: active)
        dismissCurrent()
    }

    public func dismissCurrent() {
        dismissTask?.cancel()
        widthCalibrationDismissTask?.cancel()
        isCalibratingWidth = false
        active = nil
        coordinator?.clearPersistentActivity(pluginID: id, forceCollapseHover: true)
    }

    private func pressButton(matching keywords: [String], in active: ActiveNotification) -> Bool {
        guard let button = active.banner?.buttons.first(where: { button in
            keywords.contains { button.title.lowercased().contains($0) }
        }) else {
            return false
        }
        return button.press()
    }

    private func activateApp(named name: String) {
        let running = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
        if running?.activate() != true {
            IslandLogger.system.error("Notification bridge could not activate source app")
        }
    }

    // MARK: - Simulation

    public func simulateSlackMessage() {
        let notification = IslandNotification(
            appName: "Slack",
            kind: .message,
            sender: "Alex Rivera",
            channel: "#acme-team-25",
            body: "Hey team, the latest update is ready for review."
        )
        present(notification, banner: nil, payloadID: "simulated-slack-\(UUID().uuidString)")
    }

    public func simulateOutlookEmail() {
        let notification = IslandNotification(
            appName: "Microsoft Outlook",
            kind: .email,
            sender: "Sarah Connor",
            title: "Project roadmap review",
            channel: nil,
            body: "Attached is the latest roadmap update for this quarter. Let me know if you have any questions before Friday's sync."
        )
        present(notification, banner: nil, payloadID: "simulated-outlook-\(UUID().uuidString)")
    }

    public func simulateTeamsCall() {
        let notification = IslandNotification(
            appName: "Microsoft Teams", kind: .incomingCall, sender: "Bob", channel: nil, body: "Incoming call"
        )
        present(notification, banner: nil, payloadID: "simulated-teams-\(UUID().uuidString)")
    }
}
