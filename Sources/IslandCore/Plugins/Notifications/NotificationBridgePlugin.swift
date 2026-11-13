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
    @Published public var whatsAppEnabled: Bool {
        didSet {
            UserDefaults.standard.set(whatsAppEnabled, forKey: Self.whatsAppKey)
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
    @Published public var hideWhatsAppBanner: Bool {
        didSet {
            UserDefaults.standard.set(hideWhatsAppBanner, forKey: Self.hideWhatsAppKey)
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
    @Published public var isReplying: Bool = false
    @Published public var replyDraft: String = ""
    @Published public var isSendingReply: Bool = false
    @Published public var keepUntilDismissed: Bool {
        didSet {
            UserDefaults.standard.set(keepUntilDismissed, forKey: Self.keepUntilDismissedKey)
            if !keepUntilDismissed {
                clearKeptHistory()
            } else if let active, active.notification.kind != .incomingCall, !isCalibratingWidth {
                _ = recordInHistory(active.notification, messages: active.messages, banner: active.banner, entryID: active.payloadID)
            }
            syncCoordinatorBadgeCount()
        }
    }
    @Published public private(set) var history: [NotificationHistoryEntry] = []
    @Published public private(set) var selectedHistoryIndex: Int = 0
    @Published public private(set) var isBrowsingHistory: Bool = false

    private static let slackKey = "island.notifications.slack"
    private static let teamsKey = "island.notifications.teams"
    private static let outlookKey = "island.notifications.outlook"
    private static let whatsAppKey = "island.notifications.whatsapp"
    private static let hideSlackKey = "island.notifications.hideBanner.slack"
    private static let hideTeamsKey = "island.notifications.hideBanner.teams"
    private static let hideOutlookKey = "island.notifications.hideBanner.outlook"
    private static let hideWhatsAppKey = "island.notifications.hideBanner.whatsapp"
    private static let otherAppsKey = "island.notifications.otherApps"
    private static let durationKey = "island.notifications.messageDuration"
    private static let maxWingWidthKey = "island.notifications.maxWingWidth"
    private static let keepUntilDismissedKey = "island.notifications.keepUntilDismissed"
    private static let hoverExitDismissDelay: TimeInterval = 1.5
    private static let duplicateWindow: TimeInterval = 3.0
    private static let maxHistoryCount = 50
    private static let ignoredAppNames: Set<String> = ["airdrop", "island"]

    private struct ActiveNotification {
        let payloadID: String
        let notification: IslandNotification
        let messages: [NotificationThreadMessage]
        let banner: RawBanner?
    }

    private let scanner = NotificationBannerScanner()
    private let parsers = NotificationParserSet()
    private weak var coordinator: NotchStateCoordinator?
    private var presentedKeys = Set<String>()
    private var recentSignatures: [String: Date] = [:]
    private var active: ActiveNotification?
    private var bannersByEntryID: [String: RawBanner] = [:]
    private var dismissTask: Task<Void, Never>?
    private var widthCalibrationDismissTask: Task<Void, Never>?
    private var hoverCancellable: AnyCancellable?
    private var postureCancellable: AnyCancellable?

    public init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "island.plugin.com.island.plugin.notifications.enabled") as? Bool ?? true
        slackEnabled = defaults.object(forKey: Self.slackKey) as? Bool ?? true
        teamsEnabled = defaults.object(forKey: Self.teamsKey) as? Bool ?? true
        outlookEnabled = defaults.object(forKey: Self.outlookKey) as? Bool ?? true
        whatsAppEnabled = defaults.object(forKey: Self.whatsAppKey) as? Bool ?? true
        hideSlackBanner = defaults.object(forKey: Self.hideSlackKey) as? Bool ?? false
        hideTeamsBanner = defaults.object(forKey: Self.hideTeamsKey) as? Bool ?? false
        hideOutlookBanner = defaults.object(forKey: Self.hideOutlookKey) as? Bool ?? false
        hideWhatsAppBanner = defaults.object(forKey: Self.hideWhatsAppKey) as? Bool ?? false
        otherAppsEnabled = defaults.object(forKey: Self.otherAppsKey) as? Bool ?? false
        let savedDuration = defaults.object(forKey: Self.durationKey) as? Double ?? 4.0
        messageDuration = max(1.0, min(15.0, savedDuration))
        maxWingWidth = defaults.object(forKey: Self.maxWingWidthKey) as? Double ?? 185.0
        keepUntilDismissed = defaults.object(forKey: Self.keepUntilDismissedKey) as? Bool ?? false

        scanner.onBannersChanged = { [weak self] banners in
            self?.handle(banners: banners)
        }
        syncScannerParking()
    }

    private func syncScannerParking() {
        scanner.shouldParkOffscreen = isEnabled && (
            (slackEnabled && hideSlackBanner) ||
            (teamsEnabled && hideTeamsBanner) ||
            (outlookEnabled && hideOutlookBanner) ||
            (whatsAppEnabled && hideWhatsAppBanner)
        )
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        hoverCancellable?.cancel()
        hoverCancellable = coordinator.$isHovering
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering in
                guard let self, !hovering, !self.isReplying, !self.isBrowsingHistory,
                      let kind = self.active?.notification.kind, kind != .incomingCall else { return }
                self.scheduleDismiss(after: Self.hoverExitDismissDelay)
            }
        postureCancellable?.cancel()
        postureCancellable = coordinator.$posture
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newPosture in
                guard let self, self.isBrowsingHistory, newPosture != .expandedCard else { return }
                self.closeHistory()
            }
        coordinator.onOpenKeptNotifications = { [weak self] in
            self?.openHistory(at: 0)
        }
        coordinator.registerExpandedSwipeHandler(for: id) { [weak self] direction in
            self?.handleExpandedSwipe(direction) ?? false
        }
        coordinator.registerHoverExitHandler(for: id) { [weak self] in
            guard let self, self.isBrowsingHistory, !self.isReplying else { return }
            self.closeHistory()
        }
        syncCoordinatorBadgeCount()
        scanner.start()
    }

    public func stop() {
        scanner.stop()
        dismissTask?.cancel()
        hoverCancellable?.cancel()
        postureCancellable?.cancel()
        coordinator?.onOpenKeptNotifications = nil
        coordinator?.unregisterExpandedSwipeHandler(for: id)
        coordinator?.unregisterHoverExitHandler(for: id)
        coordinator?.keptNotificationCount = 0
        presentedKeys = []
        recentSignatures = [:]
        bannersByEntryID = [:]
        history = []
        selectedHistoryIndex = 0
        isBrowsingHistory = false
        resetReplyState()
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
            guard let notification = parsed else { continue }
            if isReplying,
               let currentNotification = displayedNotification,
               let currentEntryID = displayedEntryID,
               signature(for: currentNotification) == signature(for: notification) {
                if shouldHideBanner(for: notification.appName) { banner.hideBanner() }
                if !isBrowsingHistory, let active {
                    self.active = ActiveNotification(
                        payloadID: active.payloadID,
                        notification: active.notification,
                        messages: active.messages,
                        banner: banner
                    )
                }
                if keepUntilDismissed {
                    bannersByEntryID[currentEntryID] = banner
                }
                continue
            }
            guard !isRecentDuplicate(notification) else { continue }
            if shouldHideBanner(for: notification.appName) { banner.hideBanner() }
            present(notification, banner: banner, payloadID: "\(banner.key)-\(UUID().uuidString)")
        }

        scanner.allowOnscreenForCurrentBanner = anyVisibleBanner && !anyHiddenBanner

        if let active, active.notification.kind == .incomingCall,
           let banner = active.banner, !currentKeys.contains(banner.key) {
            dismissCurrent()
        }
    }

    private func signature(for notification: IslandNotification) -> String {
        [notification.appName, notification.sender, notification.channel ?? "", notification.title ?? "", notification.body]
            .joined(separator: "\u{1F}")
    }

    /// A tray card re-exposed by hovering carries the same content as the banner shown earlier, so it
    /// must neither be presented again nor dismissed (dismissing it would remove it from the tray).
    private func isRecentDuplicate(_ notification: IslandNotification) -> Bool {
        guard notification.kind != .incomingCall else { return false }
        let now = Date()
        recentSignatures = recentSignatures.filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }
        let key = signature(for: notification)
        defer { recentSignatures[key] = now }
        return recentSignatures[key] != nil
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
        case WhatsAppNotificationParser.appName: return hideWhatsAppBanner
        default: return false
        }
    }

    private func isAppEnabled(_ appName: String) -> Bool {
        switch appName {
        case SlackNotificationParser.appName: return slackEnabled
        case TeamsNotificationParser.appName: return teamsEnabled
        case OutlookNotificationParser.appName: return outlookEnabled
        case WhatsAppNotificationParser.appName: return whatsAppEnabled
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
        let preserveReply = isReplying
            && notification.threadKey != nil
            && displayedNotification?.threadKey == notification.threadKey

        let resolvedEntryID: String
        let resolvedMessages: [NotificationThreadMessage]
        if keepUntilDismissed && !isCalibratingWidth && notification.kind != .incomingCall {
            let entry = recordInHistory(notification, banner: banner, entryID: payloadID)
            resolvedEntryID = entry.id
            resolvedMessages = entry.messages
        } else if !isCalibratingWidth,
                  let threadKey = notification.threadKey,
                  let current = active,
                  current.notification.threadKey == threadKey {
            var updated = current.messages
            updated.append(NotificationThreadMessage(notification: notification))
            if updated.count > NotificationHistoryEntry.maxMessagesPerThread {
                updated = Array(updated.suffix(NotificationHistoryEntry.maxMessagesPerThread))
            }
            resolvedEntryID = current.payloadID
            resolvedMessages = updated
        } else {
            resolvedEntryID = payloadID
            resolvedMessages = [NotificationThreadMessage(notification: notification)]
        }

        if !preserveReply {
            resetReplyState()
            isBrowsingHistory = false
        }

        if !isBrowsingHistory {
            active = ActiveNotification(
                payloadID: resolvedEntryID,
                notification: notification,
                messages: resolvedMessages,
                banner: banner
            )
        } else {
            active = nil
        }

        let isCall = notification.kind == .incomingCall
        let rightWidth = forcedRightWingWidth ?? (isCall ? 44 : Self.messageWingWidth(for: notification, maxAllowedWidth: maxWingWidth))
        let payload = makeActivityPayload(
            id: isBrowsingHistory ? "history-\(resolvedEntryID)" : resolvedEntryID,
            notification: notification,
            entryID: resolvedEntryID,
            messages: resolvedMessages,
            rightWidth: rightWidth
        )
        coordinator.publishPersistentActivity(payload)

        if !isCall && !preserveReply && !isBrowsingHistory {
            scheduleDismiss(after: messageDuration)
        }
    }

    private func resetReplyState() {
        isReplying = false
        replyDraft = ""
        isSendingReply = false
        coordinator?.isTextInputActive = false
    }

    private func makeActivityPayload(
        id payloadID: String,
        notification: IslandNotification,
        entryID: String,
        messages: [NotificationThreadMessage],
        rightWidth: CGFloat
    ) -> NotchActivityPayload {
        let isCall = notification.kind == .incomingCall
        return NotchActivityPayload(
            id: payloadID,
            pluginID: id,
            priority: isCall ? .critical : .high,
            posture: .compactWings,
            wingSizes: NotchWingSizes(leftWidth: 36, rightWidth: rightWidth),
            compactLeadingView: AnyView(NotificationCompactLeadingView(notification: notification)),
            compactTrailingView: AnyView(NotificationCompactTrailingView(notification: notification)),
            expandedView: AnyView(
                NotificationExpandedCardView(
                    plugin: self,
                    notification: notification,
                    entryID: entryID,
                    messages: messages
                )
            ),
            accentColor: isCall ? .green : .white
        )
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
            if coordinator.isHovering || coordinator.posture == .expandedCard || self.isReplying || self.isBrowsingHistory { return }
            self.collapseToast()
        }
    }

    // MARK: - History & Swipe Navigation

    @discardableResult
    private func recordInHistory(
        _ notification: IslandNotification,
        messages: [NotificationThreadMessage]? = nil,
        banner: RawBanner?,
        entryID: String
    ) -> NotificationHistoryEntry {
        let entry: NotificationHistoryEntry
        if let threadKey = notification.threadKey,
           let existingIndex = history.firstIndex(where: { $0.notification.threadKey == threadKey }) {
            let existing = history.remove(at: existingIndex)
            entry = existing.appending(notification)
        } else {
            history.removeAll { $0.id == entryID }
            entry = NotificationHistoryEntry(id: entryID, notification: notification, messages: messages)
        }

        history.insert(entry, at: 0)
        if let banner {
            bannersByEntryID[entry.id] = banner
        }
        if history.count > Self.maxHistoryCount {
            let evicted = history.dropFirst(Self.maxHistoryCount)
            for item in evicted {
                bannersByEntryID.removeValue(forKey: item.id)
            }
            history = Array(history.prefix(Self.maxHistoryCount))
        }
        selectedHistoryIndex = 0
        syncCoordinatorBadgeCount()
        return entry
    }

    private func clearKeptHistory() {
        history.removeAll()
        bannersByEntryID.removeAll()
        selectedHistoryIndex = 0
        if isBrowsingHistory {
            closeHistory()
        }
        syncCoordinatorBadgeCount()
    }

    private func syncCoordinatorBadgeCount() {
        coordinator?.keptNotificationCount = keepUntilDismissed ? history.count : 0
    }

    public func openHistory(at index: Int = 0) {
        guard keepUntilDismissed,
              !history.isEmpty,
              active?.notification.kind != .incomingCall,
              let coordinator else { return }
        if coordinator.persistentActivity?.priority == .critical && coordinator.persistentActivity?.pluginID != id {
            return
        }
        dismissTask?.cancel()
        resetReplyState()
        active = nil

        let clamped = max(0, min(index, history.count - 1))
        selectedHistoryIndex = clamped
        isBrowsingHistory = true

        let entry = history[clamped]
        let rightWidth = Self.messageWingWidth(for: entry.notification, maxAllowedWidth: maxWingWidth)
        let payload = makeActivityPayload(
            id: "history-\(entry.id)",
            notification: entry.notification,
            entryID: entry.id,
            messages: entry.messages,
            rightWidth: rightWidth
        )
        coordinator.publishPersistentActivity(payload)
        if coordinator.posture != .expandedCard {
            coordinator.handleNotchClicked()
        }
    }

    public func closeHistory() {
        guard isBrowsingHistory else { return }
        isBrowsingHistory = false
        resetReplyState()
        active = nil
        coordinator?.clearPersistentActivity(pluginID: id, forceCollapseHover: false)
    }

    public func showNextNotification() {
        guard keepUntilDismissed, !history.isEmpty else { return }
        if !isBrowsingHistory {
            if active != nil, history.count > 1 {
                openHistory(at: 1)
            } else if active == nil {
                openHistory(at: 0)
            }
            return
        }
        let nextIndex = selectedHistoryIndex + 1
        guard nextIndex < history.count else { return }
        openHistory(at: nextIndex)
    }

    public func showPreviousNotification() {
        guard keepUntilDismissed, isBrowsingHistory else { return }
        if selectedHistoryIndex > 0 {
            openHistory(at: selectedHistoryIndex - 1)
        } else {
            closeHistory()
        }
    }

    public func clearAllHistory() {
        history.removeAll()
        bannersByEntryID.removeAll()
        selectedHistoryIndex = 0
        syncCoordinatorBadgeCount()
        if isBrowsingHistory || active != nil {
            isBrowsingHistory = false
            resetReplyState()
            active = nil
            coordinator?.clearPersistentActivity(pluginID: id, forceCollapseHover: true)
        }
    }

    @discardableResult
    public func handleExpandedSwipe(_ direction: NotchSwipeDirection) -> Bool {
        guard !isReplying else { return false }
        if active?.notification.kind == .incomingCall { return false }
        let isViewingNotifications = isBrowsingHistory || (
            active != nil && coordinator?.persistentActivity?.pluginID == id
        )
        if !isViewingNotifications {
            if keepUntilDismissed,
               direction == .down,
               !history.isEmpty,
               coordinator?.persistentActivity?.priority != .critical {
                openHistory(at: 0)
                return true
            }
            return false
        }
        switch direction {
        case .left:
            if keepUntilDismissed {
                let prevBrowsing = isBrowsingHistory
                let prevIndex = selectedHistoryIndex
                showNextNotification()
                return isBrowsingHistory != prevBrowsing || selectedHistoryIndex != prevIndex
            }
            return false
        case .right:
            if keepUntilDismissed, isBrowsingHistory, selectedHistoryIndex > 0 {
                showPreviousNotification()
                return true
            }
            return false
        case .up:
            if isBrowsingHistory {
                closeHistory()
                return true
            } else if active != nil {
                collapseToast()
                return true
            }
            return false
        case .down:
            return false
        }
    }

    public func canReply(to notification: IslandNotification, entryID: String?) -> Bool {
        guard notification.canReply else { return false }
        if let entryID, let banner = bannersByEntryID[entryID] {
            return banner.isBannerAlive()
        }
        if !isBrowsingHistory, let banner = active?.banner {
            return banner.isBannerAlive()
        }
        return false
    }

    private var displayedEntryID: String? {
        if isBrowsingHistory, history.indices.contains(selectedHistoryIndex) {
            return history[selectedHistoryIndex].id
        }
        return active?.payloadID
    }

    private var displayedNotification: IslandNotification? {
        if isBrowsingHistory, history.indices.contains(selectedHistoryIndex) {
            return history[selectedHistoryIndex].notification
        }
        return active?.notification
    }

    private var displayedBanner: RawBanner? {
        if isBrowsingHistory, history.indices.contains(selectedHistoryIndex) {
            return bannersByEntryID[history[selectedHistoryIndex].id]
        }
        return active?.banner
    }

    // MARK: - Actions

    public func beginReply() {
        dismissTask?.cancel()
        isReplying = true
        replyDraft = ""
        coordinator?.isTextInputActive = true
        _ = displayedBanner?.beginReply()
    }

    public func cancelReply() {
        isReplying = false
        replyDraft = ""
        isSendingReply = false
        coordinator?.isTextInputActive = false
        if !isBrowsingHistory, let active, active.notification.kind != .incomingCall {
            scheduleDismiss(after: messageDuration)
        }
    }

    public func submitReply() {
        let trimmed = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSendingReply = true
        let success = displayedBanner?.sendReply(trimmed) ?? true
        IslandLogger.system.info("submitReply result: \(success, privacy: .public)")

        isSendingReply = false
        isReplying = false
        replyDraft = ""
        coordinator?.isTextInputActive = false
        dismissCurrent()
    }

    public func openCurrent() {
        guard let notification = displayedNotification else { return }
        let opened = displayedBanner?.pressBanner() ?? false
        if !opened {
            IslandLogger.system.info("pressBanner failed or unavailable; falling back to app activation")
            activateApp(named: notification.appName)
        }
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

    private func collapseToast() {
        dismissTask?.cancel()
        widthCalibrationDismissTask?.cancel()
        isCalibratingWidth = false
        resetReplyState()
        if let oldID = active?.payloadID, !history.contains(where: { $0.id == oldID }) {
            bannersByEntryID.removeValue(forKey: oldID)
        }
        active = nil
        if !isBrowsingHistory {
            coordinator?.clearPersistentActivity(pluginID: id, forceCollapseHover: false)
        }
    }

    public func dismissCurrent() {
        dismissTask?.cancel()
        widthCalibrationDismissTask?.cancel()
        isCalibratingWidth = false
        resetReplyState()

        if let removedID = displayedEntryID {
            history.removeAll { $0.id == removedID }
            bannersByEntryID.removeValue(forKey: removedID)
            syncCoordinatorBadgeCount()
        }

        if isBrowsingHistory {
            active = nil
            if !history.isEmpty {
                let nextIndex = min(selectedHistoryIndex, history.count - 1)
                openHistory(at: nextIndex)
                return
            }
            isBrowsingHistory = false
        }

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
        let target = BannerTextCleaner.trim(name)
        let running = NSWorkspace.shared.runningApplications.first {
            guard let localized = $0.localizedName else { return false }
            return BannerTextCleaner.trim(localized).caseInsensitiveCompare(target) == .orderedSame
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
            body: "Hey team, the latest update is ready for review. Can someone check the staging deployment before 4 PM?"
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

    public func simulateWhatsAppMessage() {
        let notification = IslandNotification(
            appName: "WhatsApp",
            kind: .message,
            sender: "Sam Carter",
            channel: "Weekend Plans",
            body: "Are we still meeting for dinner at 7 PM tonight? Let me know if I should book a table."
        )
        present(notification, banner: nil, payloadID: "simulated-whatsapp-\(UUID().uuidString)")
    }
}
