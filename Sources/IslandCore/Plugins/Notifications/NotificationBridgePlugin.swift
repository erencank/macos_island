import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class NotificationBridgePlugin: ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.notifications"
    public let displayName = "App Notifications"
    public let symbolName = "bell.badge.fill"

    @Published public var isEnabled: Bool
    @Published public var slackEnabled: Bool {
        didSet { UserDefaults.standard.set(slackEnabled, forKey: Self.slackKey) }
    }
    @Published public var teamsEnabled: Bool {
        didSet { UserDefaults.standard.set(teamsEnabled, forKey: Self.teamsKey) }
    }
    @Published public var outlookEnabled: Bool {
        didSet { UserDefaults.standard.set(outlookEnabled, forKey: Self.outlookKey) }
    }
    @Published public var hideSlackBanner: Bool {
        didSet { UserDefaults.standard.set(hideSlackBanner, forKey: Self.hideSlackKey) }
    }
    @Published public var hideTeamsBanner: Bool {
        didSet { UserDefaults.standard.set(hideTeamsBanner, forKey: Self.hideTeamsKey) }
    }
    @Published public var hideOutlookBanner: Bool {
        didSet { UserDefaults.standard.set(hideOutlookBanner, forKey: Self.hideOutlookKey) }
    }
    @Published public var otherAppsEnabled: Bool {
        didSet { UserDefaults.standard.set(otherAppsEnabled, forKey: Self.otherAppsKey) }
    }
    @Published public var messageDuration: Double {
        didSet { UserDefaults.standard.set(messageDuration, forKey: Self.durationKey) }
    }

    private static let slackKey = "island.notifications.slack"
    private static let teamsKey = "island.notifications.teams"
    private static let outlookKey = "island.notifications.outlook"
    private static let hideSlackKey = "island.notifications.hideBanner.slack"
    private static let hideTeamsKey = "island.notifications.hideBanner.teams"
    private static let hideOutlookKey = "island.notifications.hideBanner.outlook"
    private static let otherAppsKey = "island.notifications.otherApps"
    private static let durationKey = "island.notifications.messageDuration"
    private static let hoverExitDismissDelay: TimeInterval = 1.5
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
    private var active: ActiveNotification?
    private var dismissTask: Task<Void, Never>?
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
        messageDuration = defaults.object(forKey: Self.durationKey) as? Double ?? 4.0

        scanner.onBannersChanged = { [weak self] banners in
            self?.handle(banners: banners)
        }
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

        for banner in banners where !presentedKeys.contains(banner.key) {
            presentedKeys.insert(banner.key)
            guard let notification = notification(for: banner) else { continue }
            if shouldHideBanner(for: notification.appName) { banner.hideBanner() }
            present(notification, banner: banner, payloadID: banner.key)
        }

        if let active, active.notification.kind == .incomingCall,
           let banner = active.banner, !currentKeys.contains(banner.key) {
            dismissCurrent()
        }
    }

    private func notification(for banner: RawBanner) -> IslandNotification? {
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
        case SlackNotificationParser().appName: return hideSlackBanner
        case TeamsNotificationParser().appName: return hideTeamsBanner
        case OutlookNotificationParser().appName: return hideOutlookBanner
        default: return false
        }
    }

    private func isAppEnabled(_ appName: String) -> Bool {
        switch appName {
        case SlackNotificationParser().appName: return slackEnabled
        case TeamsNotificationParser().appName: return teamsEnabled
        case OutlookNotificationParser().appName: return outlookEnabled
        default: return false
        }
    }

    // MARK: - Presentation

    private func present(_ notification: IslandNotification, banner: RawBanner?, payloadID: String) {
        guard isEnabled, let coordinator else { return }
        if active?.notification.kind == .incomingCall, notification.kind != .incomingCall { return }

        dismissTask?.cancel()
        active = ActiveNotification(payloadID: payloadID, notification: notification, banner: banner)

        let isCall = notification.kind == .incomingCall
        let payload = NotchActivityPayload(
            id: payloadID,
            pluginID: id,
            priority: isCall ? .critical : .high,
            posture: .compactWings,
            wingSizes: NotchWingSizes(leftWidth: 36, rightWidth: isCall ? 44 : Self.messageWingWidth(for: notification)),
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

    private static func messageWingWidth(for notification: IslandNotification) -> CGFloat {
        let estimated = CGFloat(notification.headline.count) * 6.6 + 16
        return min(max(estimated, 56), 150)
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
            appName: "Slack", kind: .message, sender: "Alice", channel: "#general", body: "Standup moved to 10:30"
        )
        present(notification, banner: nil, payloadID: "simulated-slack-\(UUID().uuidString)")
    }

    public func simulateOutlookEmail() {
        let notification = IslandNotification(
            appName: "Microsoft Outlook", kind: .email, sender: "Dana Lee",
            channel: nil, body: "Q4 planning notes\nAttached are the notes from today's session."
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
