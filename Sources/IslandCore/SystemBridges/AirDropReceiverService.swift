import AppKit
import ApplicationServices
import Combine
import Darwin
import Foundation

public enum AirDropTransferPhase: String, Equatable, Sendable {
    case awaitingConfirmation
    case transferring
    case completed
    case declined
    case failed
}

public enum AirDropPayloadKind: Equatable, Sendable {
    case files(count: Int)
    case webLink(url: URL?)
}

public struct AirDropTransferSession: Identifiable, Equatable {
    public let id: String
    public var senderName: String
    public var itemTitle: String
    public var itemSubtitle: String
    public var payloadKind: AirDropPayloadKind
    public var phase: AirDropTransferPhase
    public var progress: Double
    public var isIndeterminateProgress: Bool
    public var previewImage: NSImage?
    public var completedURLs: [URL]
    public var isSimulated: Bool

    public init(
        id: String,
        senderName: String,
        itemTitle: String,
        itemSubtitle: String,
        payloadKind: AirDropPayloadKind,
        phase: AirDropTransferPhase,
        progress: Double = 0.0,
        isIndeterminateProgress: Bool = false,
        previewImage: NSImage? = nil,
        completedURLs: [URL] = [],
        isSimulated: Bool = false
    ) {
        self.id = id
        self.senderName = senderName
        self.itemTitle = itemTitle
        self.itemSubtitle = itemSubtitle
        self.payloadKind = payloadKind
        self.phase = phase
        self.progress = progress
        self.isIndeterminateProgress = isIndeterminateProgress
        self.previewImage = previewImage
        self.completedURLs = completedURLs
        self.isSimulated = isSimulated
    }
}

/// Bridges macOS `Sharing.framework` (`SFAirDropTransferObserver`) and a `~/Downloads` auto-accept
/// directory watcher to detect incoming AirDrop file/link transfers and trigger Accept/Decline actions.
@MainActor
public final class AirDropReceiverService: NSObject, ObservableObject {
    @Published public private(set) var activeSession: AirDropTransferSession?

    private var sharingFrameworkHandle: UnsafeMutableRawPointer?
    private var transferObserver: NSObject?
    private var liveTransfersByID: [String: NSObject] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private var downloadsProgressSubscriber: Any?
    private var downloadsDescriptor: Int32 = -1
    private var downloadsSource: DispatchSourceFileSystemObject?
    private var knownDownloadsSnapshot = Set<String>()
    private var transferAcceptedAt: Date?
    private var observedCandidateFileSizes: [String: UInt64] = [:]
    private var bannerDisappearedDuringTransferAt: Date?
    private var simulationTask: Task<Void, Never>?
    private var notificationCenterPollTimer: Timer?
    private var axAcceptElement: AXUIElement?
    private var axDeclineElement: AXUIElement?
    private var axShowInFinderElement: AXUIElement?
    private var axBannerElement: AXUIElement?
    private var hiddenWindowElement: AXUIElement?
    private var hiddenWindowOriginalOrigin: CGPoint?
    private var lastDetectedBannerText: String?
    private var lastLoggedAXTrustState: Bool?
    private var shouldSuppressSystemBanner: Bool = true

    public var onSessionUpdated: ((AirDropTransferSession?) -> Void)?

    public override init() {
        super.init()
    }

    public func start(replaceSystemNotification: Bool) {
        stop()
        self.shouldSuppressSystemBanner = replaceSystemNotification
        startSharingFrameworkObserver(replaceSystemNotification: replaceSystemNotification)
        startNotificationCenterAXMonitor()
        startDownloadsAutoAcceptWatcher()
    }

    public func stop() {
        simulationTask?.cancel()
        simulationTask = nil

        notificationCenterPollTimer?.invalidate()
        notificationCenterPollTimer = nil
        axAcceptElement = nil
        axDeclineElement = nil
        axBannerElement = nil
        lastDetectedBannerText = nil

        for (_, obs) in progressObservations {
            obs.invalidate()
        }
        progressObservations.removeAll()
        liveTransfersByID.removeAll()

        if let sub = downloadsProgressSubscriber {
            Progress.removeSubscriber(sub)
            downloadsProgressSubscriber = nil
        }

        if let observer = transferObserver {
            let invalidateSel = NSSelectorFromString("invalidate")
            if observer.responds(to: invalidateSel) {
                _ = observer.perform(invalidateSel)
            }
            transferObserver = nil
        }

        downloadsSource?.cancel()
        downloadsSource = nil
        if downloadsDescriptor >= 0 {
            close(downloadsDescriptor)
            downloadsDescriptor = -1
        }
    }

    // MARK: - User Actions (Accept / Decline / Open)

    public func acceptCurrentTransfer() {
        guard var session = activeSession else { return }

        if session.isSimulated {
            runSimulatedAcceptFlow(for: session)
            return
        }

        // Snapshot `~/Downloads` and timestamp right before triggering Accept so we only match
        // files created or updated by THIS transfer.
        transferAcceptedAt = Date()
        observedCandidateFileSizes.removeAll()
        bannerDisappearedDuringTransferAt = nil
        if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            knownDownloadsSnapshot = Set((try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path)) ?? [])
        }

        let hasLiveSharingTransfer = (liveTransfersByID[session.id] != nil)
        if let rawTransfer = liveTransfersByID[session.id] {
            triggerPossibleAction(on: rawTransfer, isCancel: false)
        } else if triggerNotificationCenterAXAction(isAccept: true) {
            IslandLogger.system.info("Triggered Accept on NotificationCenter AirDrop banner via Accessibility")
        }

        let isLinkSession: Bool = {
            if case .webLink = session.payloadKind { return true }
            return false
        }()

        session.phase = .transferring
        session.itemSubtitle = "Receiving via AirDrop…"
        session.isIndeterminateProgress = !hasLiveSharingTransfer && !isLinkSession
        session.progress = session.isIndeterminateProgress ? 0.0 : max(session.progress, 0.06)
        updateSession(session)

        simulationTask?.cancel()
        simulationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Web links open directly in the browser without writing a file to ~/Downloads
            if isLinkSession {
                for pct in [0.45, 0.85, 1.0] {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled,
                          var current = self.activeSession,
                          current.id == session.id,
                          current.phase == .transferring else { return }
                    current.progress = pct
                    current.isIndeterminateProgress = false
                    if pct >= 1.0 {
                        current.phase = .completed
                        current.itemSubtitle = "Opened in Browser"
                    }
                    self.updateSession(current)
                }
                return
            }

            // For file/photo transfers, poll ~/Downloads every 400ms until the actual completed file lands on disk.
            // Real byte progress is driven by `Progress.addSubscriber(forFileURL:)` or `AXProgressIndicator` when available;
            // otherwise `isIndeterminateProgress` stays true so the UI renders a continuous animated spinner instead of freezing at 92%.
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled,
                      let current = self.activeSession,
                      current.id == session.id,
                      current.phase == .transferring else { return }

                if self.checkForCompletedDownloadSinceAccept() {
                    return
                }

                ticks += 1
                // Safety timeout after 3 minutes (450 * 0.4s) if the transfer stalled completely
                if ticks > 450 {
                    print("[Island AirDrop] Transfer timed out waiting for file in ~/Downloads")
                    self.clearActiveSession()
                    return
                }
            }
        }
    }

    public func declineCurrentTransfer() {
        guard var session = activeSession else { return }
        simulationTask?.cancel()

        if !session.isSimulated {
            if let rawTransfer = liveTransfersByID[session.id] {
                triggerPossibleAction(on: rawTransfer, isCancel: true)
            } else if triggerNotificationCenterAXAction(isAccept: false) {
                IslandLogger.system.info("Triggered Decline on NotificationCenter AirDrop banner via Accessibility")
            } else {
                dismissNotificationCenterBannerElement()
            }
        }

        restoreHiddenNotificationCenterWindowIfNeeded()
        axAcceptElement = nil
        axDeclineElement = nil
        axShowInFinderElement = nil
        axBannerElement = nil
        lastDetectedBannerText = nil
        transferAcceptedAt = nil
        observedCandidateFileSizes.removeAll()
        bannerDisappearedDuringTransferAt = nil
        session.phase = .declined
        updateSession(nil)
    }

    public func clearActiveSession() {
        let wasTransferring = (activeSession?.phase == .transferring)
        simulationTask?.cancel()
        simulationTask = nil
        // Close the finished NotificationCenter completion banner once the session is `.completed`
        // so NotificationCenter is ready for the next incoming AirDrop!
        if !wasTransferring {
            dismissNotificationCenterBannerElement()
        }
        restoreHiddenNotificationCenterWindowIfNeeded()
        axAcceptElement = nil
        axDeclineElement = nil
        axShowInFinderElement = nil
        axBannerElement = nil
        lastDetectedBannerText = nil
        transferAcceptedAt = nil
        observedCandidateFileSizes.removeAll()
        bannerDisappearedDuringTransferAt = nil
        updateSession(nil)
    }

    private func restoreHiddenNotificationCenterWindowIfNeeded() {
        var orig: CGPoint = {
            if let saved = hiddenWindowOriginalOrigin {
                return saved
            }
            let x = UserDefaults.standard.double(forKey: "island.airdrop.ncOrigX")
            let y = UserDefaults.standard.double(forKey: "island.airdrop.ncOrigY")
            if x > 0 && x < 8000 {
                return CGPoint(x: x, y: y)
            }
            let screenWidth = NSScreen.main?.frame.width ?? 1512
            return CGPoint(x: max(100, screenWidth - 380), y: 38)
        }()

        if let win = hiddenWindowElement, let posVal = AXValueCreate(.cgPoint, &orig) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        }

        // Also scan all NotificationCenter windows in case a previous process died while a window was at x=12000
        if let ncApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) {
            let axApp = AXUIElementCreateApplication(ncApp.processIdentifier)
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &childrenRef) == .success,
               let windows = childrenRef as? [AXUIElement] {
                for win in windows {
                    var posRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                       let val = posRef {
                        var pt = CGPoint.zero
                        if AXValueGetValue(val as! AXValue, .cgPoint, &pt), pt.x >= 8000,
                           let posVal = AXValueCreate(.cgPoint, &orig) {
                            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
                        }
                    }
                }
            }
        }

        hiddenWindowElement = nil
        hiddenWindowOriginalOrigin = nil
    }

    private func dismissNotificationCenterBannerElement() {
        guard let banner = axBannerElement else { return }
        var actionNamesRef: CFArray?
        if AXUIElementCopyActionNames(banner, &actionNamesRef) == .success,
           let actions = actionNamesRef as? [String] {
            if let closeAction = actions.first(where: {
                let lower = $0.lowercased()
                return lower.contains("close") || lower.contains("cancel") || lower.contains("sluit")
            }) {
                _ = AXUIElementPerformAction(banner, closeAction as CFString)
            }
        }
    }

    // MARK: - Simulation Helpers for Interactive Testing

    public func simulateIncomingFileTransfer() {
        simulationTask?.cancel()
        let session = AirDropTransferSession(
            id: "sim-file-\(UUID().uuidString)",
            senderName: "Erencan’s iPhone",
            itemTitle: "IMG_4821.HEIC",
            itemSubtitle: "Photo • 4.2 MB",
            payloadKind: .files(count: 1),
            phase: .awaitingConfirmation,
            progress: 0.0,
            previewImage: NSImage(systemSymbolName: "photo.fill", accessibilityDescription: "Photo"),
            completedURLs: [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())],
            isSimulated: true
        )
        updateSession(session)
    }

    public func simulateIncomingLinkShare() {
        simulationTask?.cancel()
        let url = URL(string: "https://developer.apple.com")!
        let session = AirDropTransferSession(
            id: "sim-link-\(UUID().uuidString)",
            senderName: "Erencan’s iPhone",
            itemTitle: "developer.apple.com",
            itemSubtitle: "Web Link • Safari",
            payloadKind: .webLink(url: url),
            phase: .awaitingConfirmation,
            progress: 0.0,
            previewImage: NSImage(systemSymbolName: "safari.fill", accessibilityDescription: "Link"),
            completedURLs: [url],
            isSimulated: true
        )
        updateSession(session)
    }

    private func runSimulatedAcceptFlow(for initial: AirDropTransferSession) {
        simulationTask?.cancel()
        var current = initial
        current.phase = .transferring
        current.progress = 0.12
        updateSession(current)

        simulationTask = Task { @MainActor [weak self] in
            let steps = [0.28, 0.52, 0.78, 0.96, 1.0]
            for pct in steps {
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard !Task.isCancelled, let self else { return }
                current.progress = pct
                if pct >= 1.0 {
                    current.phase = .completed
                }
                self.updateSession(current)
            }
        }
    }

    // MARK: - 1. Native `Sharing.framework` (`SFAirDropTransferObserver`)

    private func startSharingFrameworkObserver(replaceSystemNotification: Bool) {
        if sharingFrameworkHandle == nil {
            sharingFrameworkHandle = dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_LAZY)
        }

        guard let observerClass = NSClassFromString("SFAirDropTransferObserver") as? NSObject.Type else {
            IslandLogger.system.error("SFAirDropTransferObserver class unavailable in Sharing.framework")
            return
        }

        let observer = observerClass.init()
        let setDelegateSel = NSSelectorFromString("setDelegate:")
        if observer.responds(to: setDelegateSel) {
            _ = observer.perform(setDelegateSel, with: self)
        }

        let activateSel = NSSelectorFromString("activate")
        if observer.responds(to: activateSel) {
            _ = observer.perform(activateSel)
        }

        if replaceSystemNotification {
            registerAsTransferPresenterIfSupported(observer: observer)
        }

        self.transferObserver = observer
        IslandLogger.system.info("Activated SFAirDropTransferObserver (replaceSystemNotification: \(replaceSystemNotification))")
    }

    private func registerAsTransferPresenterIfSupported(observer: NSObject) {
        // Attempt to access modernObserver -> client to take presenter ownership if available
        let modernSel = NSSelectorFromString("modernObserver")
        guard observer.responds(to: modernSel),
              let modernObj = observer.perform(modernSel)?.takeUnretainedValue() as? NSObject else {
            return
        }
        // Keep reference active; `SFAirDropTransferObserver` automatically registers with `sharingd` XPC.
        _ = modernObj
    }

    /// Objective-C callback invoked by `SFAirDropTransferObserver` whenever an incoming or active AirDrop transfer updates.
    @objc(updatedTransfer:)
    public func updatedTransfer(_ transferObj: AnyObject) {
        Task { @MainActor [weak self] in
            guard let self, let obj = transferObj as? NSObject else { return }
            self.handleRawTransferUpdate(obj, removed: false)
        }
    }

    /// Objective-C callback invoked by `SFAirDropTransferObserver` when an AirDrop transfer is removed/dismissed.
    @objc(removedTransfer:)
    public func removedTransfer(_ transferObj: AnyObject) {
        Task { @MainActor [weak self] in
            guard let self, let obj = transferObj as? NSObject else { return }
            self.handleRawTransferUpdate(obj, removed: true)
        }
    }

    private func handleRawTransferUpdate(_ transfer: NSObject, removed: Bool) {
        let id = (transfer.value(forKey: "identifier") as? String) ?? UUID().uuidString
        if removed {
            liveTransfersByID.removeValue(forKey: id)
            progressObservations.removeValue(forKey: id)?.invalidate()
            if activeSession?.id == id {
                updateSession(nil)
            }
            return
        }

        liveTransfersByID[id] = transfer

        let rawState = (transfer.value(forKey: "transferState") as? Int) ?? 0
        let needsAction = (transfer.value(forKey: "needsAction") as? Bool) ?? false
        let contentsTitle = (transfer.value(forKey: "contentsTitle") as? String) ?? ""
        let contentsDesc = (transfer.value(forKey: "contentsDescription") as? String) ?? ""
        let completedURLs = (transfer.value(forKey: "completedURLs") as? [URL]) ?? []

        var senderName = "AirDrop"
        var itemsDesc = contentsDesc
        var previewImg: NSImage?
        var isLinkPayload = false
        var fileCount = max(1, completedURLs.count)

        if let meta = transfer.value(forKey: "metaData") as? NSObject {
            let composite = (meta.value(forKey: "senderCompositeName") as? String) ?? ""
            let first = (meta.value(forKey: "senderFirstName") as? String) ?? ""
            let compName = (meta.value(forKey: "senderComputerName") as? String) ?? ""
            if !composite.isEmpty {
                senderName = composite
            } else if !first.isEmpty {
                senderName = first
            } else if !compName.isEmpty {
                senderName = compName
            }

            if let metaDesc = meta.value(forKey: "itemsDescription") as? String, !metaDesc.isEmpty {
                itemsDesc = metaDesc
            }

            if let rawTypes = meta.value(forKey: "transferTypes") as? UInt64 {
                // Bit 25 (0x2000000 = Links) or Bit 39 (0x8000000000 = WebLinks)
                let linkMask: UInt64 = (1 << 25) | (1 << 26) | (1 << 39)
                if (rawTypes & linkMask) != 0 {
                    isLinkPayload = true
                }
            }

            if let itemsSet = meta.value(forKey: "items") as? NSSet {
                fileCount = max(1, itemsSet.count)
            }

            if let cgImgObj = meta.value(forKey: "previewImage") ?? meta.value(forKey: "smallPreviewImage") {
                if let nsImg = cgImgObj as? NSImage {
                    previewImg = nsImg
                } else if CFGetTypeID(cgImgObj as CFTypeRef) == CGImage.typeID {
                    let cgImg = cgImgObj as! CGImage
                    previewImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                }
            }
        }

        if let firstURL = completedURLs.first,
           let scheme = firstURL.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            isLinkPayload = true
        }

        var fractionCompleted = 0.0
        if let progressObj = transfer.value(forKey: "transferProgress") as? Progress {
            fractionCompleted = progressObj.fractionCompleted
            if progressObservations[id] == nil {
                progressObservations[id] = progressObj.observe(\.fractionCompleted, options: [.new]) { [weak self] prog, _ in
                    Task { @MainActor [weak self] in
                        guard let self, var current = self.activeSession, current.id == id else { return }
                        current.progress = max(0.05, min(1.0, prog.fractionCompleted))
                        self.updateSession(current)
                    }
                }
            }
        }

        // Map `SFAirDropTransferState`:
        // 1 = Created, 2 = Transferring, 3 = SenderCancelled, 4 = Completed, 6 = ActionsStarted, 7 = ReadyForOpen, 8 = Terminated, 9 = Failed
        let phase: AirDropTransferPhase
        switch rawState {
        case 1:
            phase = needsAction ? .awaitingConfirmation : .transferring
        case 2, 6:
            phase = needsAction ? .awaitingConfirmation : .transferring
        case 4, 7:
            phase = .completed
            fractionCompleted = 1.0
        case 3, 8:
            phase = .declined
        case 9:
            phase = .failed
        default:
            phase = needsAction ? .awaitingConfirmation : .transferring
        }

        if phase == .declined || phase == .failed {
            updateSession(nil)
            return
        }

        let resolvedTitle: String = {
            if let firstURL = completedURLs.first {
                return firstURL.isFileURL ? firstURL.lastPathComponent : (firstURL.host ?? firstURL.absoluteString)
            }
            if !itemsDesc.isEmpty { return itemsDesc }
            if !contentsTitle.isEmpty { return contentsTitle }
            return isLinkPayload ? "Shared Web Link" : "AirDrop File"
        }()

        let resolvedSubtitle: String = {
            switch phase {
            case .awaitingConfirmation:
                return "wants to share \(isLinkPayload ? "a link" : (fileCount > 1 ? "\(fileCount) files" : "a file"))"
            case .transferring:
                return "Receiving via AirDrop…"
            case .completed:
                return isLinkPayload ? "Opened in Browser" : "Saved to Downloads"
            case .declined, .failed:
                return "Cancelled"
            }
        }()

        let payloadKind: AirDropPayloadKind = isLinkPayload
            ? .webLink(url: completedURLs.first)
            : .files(count: fileCount)

        let session = AirDropTransferSession(
            id: id,
            senderName: senderName,
            itemTitle: resolvedTitle,
            itemSubtitle: resolvedSubtitle,
            payloadKind: payloadKind,
            phase: phase,
            progress: fractionCompleted,
            previewImage: previewImg,
            completedURLs: completedURLs,
            isSimulated: false
        )
        updateSession(session)
    }

    private func triggerPossibleAction(on transfer: NSObject, isCancel: Bool) {
        let triggerSel = NSSelectorFromString("triggerAction")
        if isCancel {
            if let cancelAction = transfer.value(forKey: "cancelAction") as? NSObject,
               cancelAction.responds(to: triggerSel) {
                _ = cancelAction.perform(triggerSel)
                return
            }
        } else {
            if let actions = transfer.value(forKey: "possibleActions") as? [NSObject],
               let primary = actions.first,
               primary.responds(to: triggerSel) {
                _ = primary.perform(triggerSel)
                return
            }
        }
    }

    // MARK: - 1B. NotificationCenter AirDrop Banner Accessibility Monitor & Action Proxy

    public func triggerCompletionBannerAction(preferFinder: Bool) -> Bool {
        // Re-scan NotificationCenter right now in case the completion banner appeared after our last poll
        if let ncApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) {
            let axApp = AXUIElementCreateApplication(ncApp.processIdentifier)
            var alerts: [AXDiscoveredAirDropAlert] = []
            collectAirDropAlerts(from: axApp, depth: 0, into: &alerts)
            if let latest = alerts.first {
                axBannerElement = latest.bannerElement
                axAcceptElement = latest.buttons.first(where: {
                    let lower = $0.title.lowercased()
                    return lower.contains("open") || lower.contains("accept") || lower.contains("save")
                })?.element
                axShowInFinderElement = latest.buttons.first(where: {
                    let lower = $0.title.lowercased()
                    return lower.contains("finder") || lower.contains("toon")
                })?.element
            }
        }

        if preferFinder {
            if let finderBtn = axShowInFinderElement {
                if performButtonOrFirstMenuChildAction(finderBtn) {
                    return true
                }
            }
            if let banner = axBannerElement, performMatchingBannerCustomAction(banner, keywords: ["finder", "show", "toon"]) {
                return true
            }
        } else {
            if let openBtn = axAcceptElement {
                if performButtonOrFirstMenuChildAction(openBtn) {
                    return true
                }
            }
            if let banner = axBannerElement, performMatchingBannerCustomAction(banner, keywords: ["open", "default", "accept"]) {
                return true
            }
        }
        return triggerNotificationCenterAXAction(isAccept: true)
    }

    private func startNotificationCenterAXMonitor() {
        notificationCenterPollTimer?.invalidate()
        lastLoggedAXTrustState = nil
        let trusted = AXIsProcessTrusted()
        lastLoggedAXTrustState = trusted
        if trusted {
            print("[Island AirDrop] ✅ NotificationCenter AX monitor started (AXIsProcessTrusted: true)")
            restoreHiddenNotificationCenterWindowIfNeeded()
        } else {
            print("[Island AirDrop] ⚠️ AXIsProcessTrusted is FALSE after rebuild! Please toggle Island OFF and ON in System Settings -> Privacy & Security -> Accessibility.")
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        notificationCenterPollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollNotificationCenterForAirDropBanner()
            }
        }
    }

    private struct AXDiscoveredAirDropAlert {
        let bannerElement: AXUIElement
        let windowElement: AXUIElement?
        let allStrings: [String]
        let buttons: [(title: String, element: AXUIElement)]
        let actions: [String]
        let progressValue: Double?
    }

    private func pollNotificationCenterForAirDropBanner() {
        let trusted = AXIsProcessTrusted()
        if lastLoggedAXTrustState != trusted {
            lastLoggedAXTrustState = trusted
            if trusted {
                print("[Island AirDrop] ✅ Accessibility permission is now TRUSTED! Monitoring NotificationCenter for AirDrop alerts.")
                restoreHiddenNotificationCenterWindowIfNeeded()
            } else {
                print("[Island AirDrop] ⚠️ Accessibility permission became UNTRUSTED (AXIsProcessTrusted: false).")
            }
        }
        guard trusted else { return }
        guard let ncApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) else {
            return
        }

        let axApp = AXUIElementCreateApplication(ncApp.processIdentifier)
        var alerts: [AXDiscoveredAirDropAlert] = []
        collectAirDropAlerts(from: axApp, depth: 0, into: &alerts)

        // Prioritize an incoming ask alert (one that has "would like to share" or a Decline button)
        // over any lingering post-transfer completion banner still in NotificationCenter!
        let preferredAlert = alerts.first(where: { candidate in
            let parsed = Self.parseAirDropAlertStrings(candidate.allStrings)
            let hasDecline = candidate.buttons.contains(where: {
                let lower = $0.title.lowercased()
                return lower.contains("decline") || lower.contains("weiger")
            })
            return parsed.isIncomingRequest || hasDecline
        }) ?? alerts.first

        guard let alert = preferredAlert else {
            // Always clear `lastDetectedBannerText` and restore the NotificationCenter window position
            // when no AirDrop banner is present so future notifications are detected immediately!
            restoreHiddenNotificationCenterWindowIfNeeded()
            lastDetectedBannerText = nil
            axAcceptElement = nil
            axDeclineElement = nil
            axShowInFinderElement = nil
            axBannerElement = nil

            // If the banner disappeared while we were still showing `.awaitingConfirmation` (e.g., sender cancelled),
            // clear the active session.
            if let current = activeSession,
               !current.isSimulated,
               current.id.hasPrefix("ax-airdrop-"),
               current.phase == .awaitingConfirmation {
                updateSession(nil)
            }
            return
        }

        let combinedText = alert.allStrings.joined(separator: " | ")
        axBannerElement = alert.bannerElement
        axAcceptElement = alert.buttons.first(where: {
            let lower = $0.title.lowercased()
            return lower.contains("accept") || lower.contains("open") || lower.contains("save") || lower.contains("accepteren")
        })?.element
        axDeclineElement = alert.buttons.first(where: {
            let lower = $0.title.lowercased()
            return lower.contains("decline") || lower.contains("cancel") || lower.contains("weiger")
        })?.element
        axShowInFinderElement = alert.buttons.first(where: {
            let lower = $0.title.lowercased()
            return lower.contains("finder") || lower.contains("toon")
        })?.element

        // If `replaceSystemNotification` is enabled, push all discovered AirDrop NotificationCenter banners offscreen
        // while keeping them alive in the Accessibility tree so Island's Accept / Decline buttons can still trigger their actions!
        if shouldSuppressSystemBanner {
            for candidate in alerts {
                hideSystemNotificationBannerOffscreen(candidate)
            }
        }

        // If NotificationCenter exposes an `AXProgressIndicator` while transferring, apply its real progress fraction!
        if let progVal = alert.progressValue, progVal > 0.0, progVal < 1.0,
           var current = activeSession, current.phase == .transferring {
            current.progress = progVal
            current.isIndeterminateProgress = false
            updateSession(current)
        }

        guard combinedText != lastDetectedBannerText || activeSession == nil else { return }
        lastDetectedBannerText = combinedText

        let parsed = Self.parseAirDropAlertStrings(alert.allStrings)

        // Distinguish between:
        // 1. An incoming request banner ("cashyos-desktop would like to share ...") -> `.awaitingConfirmation`
        // 2. A post-transfer completion banner ("Open" / "Show in Finder" without "would like to share") -> `.completed`
        let hasDeclineButton = alert.buttons.contains(where: {
            let lower = $0.title.lowercased()
            return lower.contains("decline") || lower.contains("weiger")
        })
        let hasDeclineAction = alert.actions.contains(where: {
            let lower = $0.lowercased()
            return lower.contains("decline") || lower.contains("weiger")
        })
        let isIncomingAskPrompt = parsed.isIncomingRequest || hasDeclineButton || hasDeclineAction

        if !isIncomingAskPrompt {
            // NotificationCenter is showing a transfer-progress or post-download completion banner.
            // If there is no active session in the Island (e.g. leftover completion banner from a previous transfer),
            // dismiss it immediately so NotificationCenter isn't blocked for the next AirDrop!
            if activeSession == nil {
                dismissNotificationCenterBannerElement()
                restoreHiddenNotificationCenterWindowIfNeeded()
                return
            }
            _ = checkForCompletedDownloadSinceAccept()
            return
        }

        // If we already have an active session that has been accepted (`.transferring` or `.completed`),
        // ignore repeated polls of the same ask banner while NotificationCenter is processing the Accept action!
        if let existing = activeSession, !existing.isSimulated, existing.phase != .awaitingConfirmation {
            return
        }

        print("[Island AirDrop] Detected incoming AirDrop alert from '\(parsed.sender)' -> \(parsed.itemTitle) (\(parsed.subtitle))")

        let session = AirDropTransferSession(
            id: "ax-airdrop-\(UUID().uuidString)",
            senderName: parsed.sender,
            itemTitle: parsed.itemTitle,
            itemSubtitle: parsed.subtitle,
            payloadKind: parsed.isLink ? .webLink(url: nil) : .files(count: 1),
            phase: .awaitingConfirmation,
            progress: 0.0,
            previewImage: NSImage(
                systemSymbolName: parsed.symbolName,
                accessibilityDescription: parsed.itemTitle
            ),
            completedURLs: [],
            isSimulated: false
        )
        updateSession(session)
    }

    private func hideSystemNotificationBannerOffscreen(_ alert: AXDiscoveredAirDropAlert) {
        var offscreenPoint = CGPoint(x: 12000, y: -4000)
        guard let posValue = AXValueCreate(.cgPoint, &offscreenPoint) else { return }

        // Save the original window origin before moving it offscreen so we can restore it cleanly once the AirDrop banner finishes!
        if let win = alert.windowElement {
            hiddenWindowElement = win
            if hiddenWindowOriginalOrigin == nil {
                var posRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                   let val = posRef {
                    var pt = CGPoint.zero
                    if AXValueGetValue(val as! AXValue, .cgPoint, &pt), pt.x < 8000 {
                        hiddenWindowOriginalOrigin = pt
                        UserDefaults.standard.set(Double(pt.x), forKey: "island.airdrop.ncOrigX")
                        UserDefaults.standard.set(Double(pt.y), forKey: "island.airdrop.ncOrigY")
                    }
                }
            }
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posValue)
        }

        AXUIElementSetAttributeValue(alert.bannerElement, kAXPositionAttribute as CFString, posValue)
        var current: AXUIElement = alert.bannerElement
        for _ in 0..<5 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                break
            }
            let parentElem = parent as! AXUIElement
            let role = Self.axString(parentElem, kAXRoleAttribute) ?? ""
            if role == (kAXApplicationRole as String) {
                break
            }
            AXUIElementSetAttributeValue(parentElem, kAXPositionAttribute as CFString, posValue)
            current = parentElem
        }
    }

    private func collectAirDropAlerts(
        from element: AXUIElement,
        enclosingWindow: AXUIElement? = nil,
        depth: Int,
        into results: inout [AXDiscoveredAirDropAlert]
    ) {
        guard depth <= 12 else { return }

        let role = Self.axString(element, kAXRoleAttribute) ?? ""
        let currentWindow = (role == (kAXWindowRole as String)) ? element : enclosingWindow
        let subrole = Self.axString(element, kAXSubroleAttribute) ?? ""
        if subrole == "AXNotificationCenterAlert" || subrole == "AXNotificationCenterBanner" {
            var texts: [String] = []
            var buttons: [(String, AXUIElement)] = []
            var progressVal: Double?
            var actionNamesRef: CFArray?
            AXUIElementCopyActionNames(element, &actionNamesRef)
            let actions = (actionNamesRef as? [String]) ?? []

            gatherTextsAndButtons(from: element, depth: 0, texts: &texts, buttons: &buttons, progressValue: &progressVal)
            let joined = texts.joined(separator: " ").lowercased()
            if joined.contains("airdrop") || joined.contains("would like to share") || joined.contains("wil een") {
                results.append(
                    AXDiscoveredAirDropAlert(
                        bannerElement: element,
                        windowElement: currentWindow,
                        allStrings: texts,
                        buttons: buttons,
                        actions: actions,
                        progressValue: progressVal
                    )
                )
                return
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                collectAirDropAlerts(from: child, enclosingWindow: currentWindow, depth: depth + 1, into: &results)
            }
        }
    }

    private func gatherTextsAndButtons(
        from element: AXUIElement,
        depth: Int,
        texts: inout [String],
        buttons: inout [(String, AXUIElement)],
        progressValue: inout Double?
    ) {
        guard depth <= 10 else { return }

        let role = Self.axString(element, kAXRoleAttribute) ?? ""
        let title = Self.axString(element, kAXTitleAttribute) ?? ""
        let val = Self.axString(element, kAXValueAttribute) ?? ""
        let desc = Self.axString(element, kAXDescriptionAttribute) ?? ""

        for candidate in [title, val, desc] where !candidate.isEmpty {
            if !texts.contains(candidate) {
                texts.append(candidate)
            }
        }

        if role == (kAXProgressIndicatorRole as String) {
            var rawValRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValRef) == .success,
               let num = rawValRef as? NSNumber {
                let d = num.doubleValue
                if d > 0.0 {
                    progressValue = d > 1.0 ? min(1.0, d / 100.0) : d
                }
            }
        }

        if role == (kAXButtonRole as String) || role == (kAXMenuButtonRole as String) {
            let btnLabel = !title.isEmpty ? title : (!desc.isEmpty ? desc : val)
            if !btnLabel.isEmpty {
                buttons.append((btnLabel, element))
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                gatherTextsAndButtons(from: child, depth: depth + 1, texts: &texts, buttons: &buttons, progressValue: &progressValue)
            }
        }
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    /// Parses strings like `"cashyos-desktop would like to share a photo"` into sender, item title, and icon.
    public nonisolated static func parseAirDropAlertStrings(_ strings: [String]) -> (sender: String, itemTitle: String, subtitle: String, isLink: Bool, symbolName: String, isIncomingRequest: Bool) {
        let requestLine = strings.first(where: {
            let lower = $0.lowercased()
            return lower.contains("would like to share") || lower.contains("wants to share") || lower.contains("wil ")
        })
        let isIncomingRequest = (requestLine != nil)
        let bodyLine = requestLine ?? strings.first(where: { $0.lowercased() != "airdrop" && $0.lowercased() != "accept" && $0.lowercased() != "decline" }) ?? "Incoming AirDrop"

        var sender = "AirDrop"
        var sharedWhat = "a file"

        for marker in [" would like to share ", " wants to share "] {
            if let range = bodyLine.range(of: marker, options: .caseInsensitive) {
                var extractedSender = String(bodyLine[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip leading "AirDrop, " prefix if NotificationCenter concatenated the header and sender
                if extractedSender.lowercased().hasPrefix("airdrop,") {
                    extractedSender = String(extractedSender.dropFirst("airdrop,".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let extractedItem = String(bodyLine[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extractedSender.isEmpty { sender = extractedSender }
                if !extractedItem.isEmpty { sharedWhat = extractedItem }
                break
            }
        }

        let lowerItem = sharedWhat.lowercased()
        let isLink = lowerItem.contains("link") || lowerItem.contains("url") || lowerItem.contains("website") || lowerItem.contains("http")
        let symbolName: String = {
            if isLink { return "safari.fill" }
            if lowerItem.contains("photo") || lowerItem.contains("image") { return "photo.fill" }
            if lowerItem.contains("video") || lowerItem.contains("movie") { return "video.fill" }
            if lowerItem.contains("audio") || lowerItem.contains("voice") { return "waveform" }
            return "doc.fill"
        }()

        let cleanTitle: String = {
            var trimmed = sharedWhat
            for prefix in ["a ", "an "] {
                if trimmed.lowercased().hasPrefix(prefix) {
                    trimmed = String(trimmed.dropFirst(prefix.count))
                    break
                }
            }
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }()

        return (
            sender: sender,
            itemTitle: cleanTitle,
            subtitle: "wants to share \(sharedWhat)",
            isLink: isLink,
            symbolName: symbolName,
            isIncomingRequest: isIncomingRequest
        )
    }

    /// Checks `~/Downloads` for newly written files since `transferAcceptedAt` whose byte size is > 0
    /// and has stabilized across two consecutive checks (so an actively-streaming 30–60s photo download
    /// is never marked complete until `sharingd` finishes writing the entire file).
    @discardableResult
    private func checkForCompletedDownloadSinceAccept() -> Bool {
        guard var current = activeSession,
              !current.isSimulated,
              current.phase == .transferring,
              let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return false
        }

        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let cutoffDate = (transferAcceptedAt ?? Date()).addingTimeInterval(-1.0)
        var verifiedURLs: [URL] = []

        for url in urls {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard !name.hasPrefix("."),
                  ext != "download",
                  ext != "crdownload",
                  ext != "part",
                  ext != "tmp" else {
                continue
            }

            let vals = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let created = vals?.creationDate ?? .distantPast
            let modified = vals?.contentModificationDate ?? .distantPast
            let latestDate = max(created, modified)

            let isNewName = !knownDownloadsSnapshot.contains(name)
            let isModifiedSinceAccept = latestDate >= cutoffDate
            guard isNewName || isModifiedSinceAccept else {
                continue
            }

            let size = UInt64(max(0, vals?.fileSize ?? 0))
            // A 0-byte file is a placeholder created by `sharingd` while the transfer is still starting
            guard size > 0 else {
                observedCandidateFileSizes[url.path] = 0
                continue
            }

            let previousSize = observedCandidateFileSizes[url.path]
            observedCandidateFileSizes[url.path] = size

            // Wait for the file size to remain non-zero and unchanged across two checks (>= 400ms)
            // so we never complete while `sharingd` is still streaming chunks to disk.
            if let previousSize, previousSize == size, fm.isReadableFile(atPath: url.path) {
                verifiedURLs.append(url)
            }
        }

        guard !verifiedURLs.isEmpty else {
            return false
        }

        // Sort newest first
        verifiedURLs.sort { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }

        simulationTask?.cancel()
        simulationTask = nil

        let firstURL = verifiedURLs[0]
        let fileSize = observedCandidateFileSizes[firstURL.path] ?? 0
        print("[Island AirDrop] Verified completed download in ~/Downloads: '\(firstURL.lastPathComponent)' (\(fileSize) bytes)")

        if let currentFiles = try? fm.contentsOfDirectory(atPath: downloadsURL.path) {
            knownDownloadsSnapshot = Set(currentFiles)
        }

        current.phase = .completed
        current.progress = 1.0
        current.isIndeterminateProgress = false
        current.itemTitle = verifiedURLs.count == 1 ? firstURL.lastPathComponent : "\(verifiedURLs.count) AirDrop Files"
        current.itemSubtitle = "Saved to Downloads"
        current.completedURLs = verifiedURLs
        current.previewImage = Self.previewImageForDownloadedFile(at: firstURL)
        updateSession(current)
        return true
    }

    private nonisolated static func previewImageForDownloadedFile(at fileURL: URL) -> NSImage {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "bmp"]
        if imageExtensions.contains(fileURL.pathExtension.lowercased()),
           let img = NSImage(contentsOf: fileURL) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: fileURL.path)
    }

    private func triggerNotificationCenterAXAction(isAccept: Bool) -> Bool {
        // 1. First check if the banner container itself exposes a custom AXAction (e.g., `Name:Accept...` or `Name:Save to Downloads...`).
        // On macOS NotificationCenter, custom banner actions execute the primary action directly without opening a dropdown menu!
        if let banner = axBannerElement {
            let keywords = isAccept ? ["save to downloads", "accept", "open", "accepteren"] : ["decline", "cancel", "weiger"]
            if performMatchingBannerCustomAction(banner, keywords: keywords) {
                return true
            }
        }

        // 2. Next, press the explicit Accept or Decline AXButton / AXMenuButton inside the alert.
        // Note: For photos, `"Accept ⌄"` is an `AXMenuButton` where `AXPress` opens a popup menu ("Save to Downloads" / "Open in Photos").
        if let buttonElem = isAccept ? axAcceptElement : axDeclineElement {
            if performButtonOrFirstMenuChildAction(buttonElem) {
                return true
            }
        }

        return false
    }

    private func performMatchingBannerCustomAction(_ banner: AXUIElement, keywords: [String]) -> Bool {
        var actionNamesRef: CFArray?
        guard AXUIElementCopyActionNames(banner, &actionNamesRef) == .success,
              let actions = actionNamesRef as? [String] else {
            return false
        }
        print("[Island AirDrop] Banner AXActions available: \(actions)")
        for keyword in keywords {
            if let matched = actions.first(where: { $0.lowercased().contains(keyword) }) {
                if AXUIElementPerformAction(banner, matched as CFString) == .success {
                    print("[Island AirDrop] Performed banner custom action: \(matched)")
                    return true
                }
            }
        }
        return false
    }

    private func performButtonOrFirstMenuChildAction(_ buttonElem: AXUIElement) -> Bool {
        let role = Self.axString(buttonElem, kAXRoleAttribute) ?? ""
        var actionNamesRef: CFArray?
        AXUIElementCopyActionNames(buttonElem, &actionNamesRef)
        let buttonActions = (actionNamesRef as? [String]) ?? []
        print("[Island AirDrop] Button role=\(role), actions=\(buttonActions)")

        guard AXUIElementPerformAction(buttonElem, kAXPressAction as CFString) == .success else {
            return false
        }

        // If `buttonElem` is an `AXMenuButton` (like `"Accept ⌄"` on photo AirDrops), pressing it opens an `AXMenu` child.
        // Immediately check if an `AXMenu` / `AXMenuItem` appeared ("Save to Downloads" or first item) and press it!
        if role == (kAXMenuButtonRole as String) || buttonActions.contains("AXShowMenu") {
            usleep(60_000) // 60ms for NotificationCenter to populate the menu items
            if clickFirstMenuItem(under: buttonElem) {
                return true
            }
            if let banner = axBannerElement, clickFirstMenuItem(under: banner) {
                return true
            }
        }
        return true
    }

    private func clickFirstMenuItem(under root: AXUIElement, depth: Int = 0) -> Bool {
        guard depth <= 6 else { return false }
        let role = Self.axString(root, kAXRoleAttribute) ?? ""
        if role == (kAXMenuItemRole as String) {
            let title = Self.axString(root, kAXTitleAttribute) ?? ""
            print("[Island AirDrop] Selecting menu item: '\(title)'")
            return AXUIElementPerformAction(root, kAXPressAction as CFString) == .success
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            // Prefer "Save to Downloads" if present, otherwise first menu item
            for child in children {
                let cRole = Self.axString(child, kAXRoleAttribute) ?? ""
                let cTitle = (Self.axString(child, kAXTitleAttribute) ?? "").lowercased()
                if cRole == (kAXMenuItemRole as String) && (cTitle.contains("downloads") || cTitle.contains("accept") || cTitle.contains("save")) {
                    print("[Island AirDrop] Selecting preferred menu item: '\(cTitle)'")
                    if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
            for child in children {
                if clickFirstMenuItem(under: child, depth: depth + 1) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - 2. Auto-Accept `~/Downloads` Directory Watcher & Accepted File Completion

    private func startDownloadsAutoAcceptWatcher() {
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return
        }

        knownDownloadsSnapshot = Set((try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path)) ?? [])

        let fd = open(downloadsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        downloadsDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.inspectDownloadsDirectoryForNewAirDrop(at: downloadsURL)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        downloadsSource = source
    }

    private func inspectDownloadsDirectoryForNewAirDrop(at downloadsURL: URL) {
        // When an accepted transfer is in progress, let `checkForCompletedDownloadSinceAccept()`
        // verify non-zero file size stability before updating `knownDownloadsSnapshot` or completing.
        if activeSession?.phase == .transferring {
            _ = checkForCompletedDownloadSinceAccept()
            return
        }

        let fm = FileManager.default
        guard let currentFiles = try? fm.contentsOfDirectory(atPath: downloadsURL.path) else { return }
        let currentSet = Set(currentFiles)
        let added = currentSet.subtracting(knownDownloadsSnapshot)

        // Ignore hidden/incomplete download temp files
        let validNewFiles = added.filter { name in
            !name.hasPrefix(".") && !name.hasSuffix(".download") && !name.hasSuffix(".crdownload") && !name.hasSuffix(".part") && !name.hasSuffix(".tmp")
        }
        guard !validNewFiles.isEmpty else {
            knownDownloadsSnapshot = currentSet
            return
        }

        var airDropURLs: [URL] = []
        var detectedSender: String? = activeSession?.senderName

        for fileName in validNewFiles {
            let fileURL = downloadsURL.appendingPathComponent(fileName)
            let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
            // Ignore 0-byte placeholders; wait for the next write event when bytes are flushed
            guard size > 0 else { continue }

            if let sender = Self.inspectAirDropExtendedAttributes(for: fileURL) {
                airDropURLs.append(fileURL)
                if !sender.isEmpty && sender != "AirDrop" {
                    detectedSender = sender
                }
            }
        }

        guard !airDropURLs.isEmpty else { return }
        knownDownloadsSnapshot = currentSet

        simulationTask?.cancel()
        let firstURL = airDropURLs[0]
        let thumb = Self.previewImageForDownloadedFile(at: firstURL)
        let session = AirDropTransferSession(
            id: activeSession?.id ?? "airdrop-dl-\(UUID().uuidString)",
            senderName: detectedSender ?? "AirDrop",
            itemTitle: airDropURLs.count == 1 ? firstURL.lastPathComponent : "\(airDropURLs.count) AirDrop Files",
            itemSubtitle: "Saved to Downloads",
            payloadKind: .files(count: airDropURLs.count),
            phase: .completed,
            progress: 1.0,
            previewImage: thumb,
            completedURLs: airDropURLs,
            isSimulated: false
        )
        updateSession(session)
    }

    /// Checks whether a newly created file in `~/Downloads` was written by `sharingd` / AirDrop
    /// via `com.apple.quarantine` or `com.apple.metadata:kMDItemWhereFroms` extended attributes.
    private static func inspectAirDropExtendedAttributes(for fileURL: URL) -> String? {
        let path = fileURL.path

        // Check `com.apple.quarantine` for `sharingd` or `AirDrop`
        let qLength = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        if qLength > 0 {
            var buffer = [CChar](repeating: 0, count: qLength + 1)
            if getxattr(path, "com.apple.quarantine", &buffer, qLength, 0, 0) > 0 {
                let qStr = String(cString: buffer).lowercased()
                if qStr.contains("sharingd") || qStr.contains("airdrop") {
                    return "AirDrop"
                }
            }
        }

        // Check `com.apple.FinderInfo` / `com.apple.metadata:kMDItemIsScreenCapture` or `kMDItemWhereFroms`
        let wfLength = getxattr(path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0)
        if wfLength > 0 {
            var rawBytes = [UInt8](repeating: 0, count: wfLength)
            if getxattr(path, "com.apple.metadata:kMDItemWhereFroms", &rawBytes, wfLength, 0, 0) > 0 {
                let data = Data(rawBytes)
                if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String],
                   let firstSource = plist.first,
                   !firstSource.hasPrefix("http") {
                    // AirDrop sets `kMDItemWhereFroms` to the sender's person/device name (whereas browsers set an HTTP URL)
                    return firstSource
                }
            }
        }

        return nil
    }

    private func updateSession(_ session: AirDropTransferSession?) {
        activeSession = session
        onSessionUpdated?(session)
    }
}
