import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

public enum AirDropOutgoingPhase: Equatable, Sendable {
    case dropzoneHover
    case selectingRecipient
    case sending(recipientName: String)
    case completed(recipientName: String)

    public var isSending: Bool {
        if case .sending = self { return true }
        return false
    }

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

public struct AirDropDiscoveredRecipient: Identifiable, Equatable {
    public let id: String
    public var displayName: String
    public var secondaryName: String?
    public var deviceModel: String
    public var avatarIcon: NSImage?
    public var isSimulated: Bool

    public init(
        id: String,
        displayName: String,
        secondaryName: String? = nil,
        deviceModel: String = "iPhone",
        avatarIcon: NSImage? = nil,
        isSimulated: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.secondaryName = secondaryName
        self.deviceModel = deviceModel
        self.avatarIcon = avatarIcon
        self.isSimulated = isSimulated
    }

    public static func == (lhs: AirDropDiscoveredRecipient, rhs: AirDropDiscoveredRecipient) -> Bool {
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.secondaryName == rhs.secondaryName &&
        lhs.deviceModel == rhs.deviceModel &&
        lhs.isSimulated == rhs.isSimulated
    }

    public var deviceSymbolName: String {
        let lower = (deviceModel + " " + displayName).lowercased()
        if lower.contains("ipad") {
            return "ipad"
        } else if lower.contains("macbook") || lower.contains("laptop") {
            return "laptopcomputer"
        } else if lower.contains("imac") || lower.contains("mac studio") || lower.contains("mac mini") || lower.contains("mac pro") || lower.contains("mac") {
            return "desktopcomputer"
        } else if lower.contains("vision") {
            return "visionpro"
        }
        return "iphone"
    }
}

public struct AirDropOutgoingSession: Identifiable, Equatable {
    public let id: String
    public var fileURLs: [URL]
    public var phase: AirDropOutgoingPhase
    public var recipients: [AirDropDiscoveredRecipient]
    public var previewImage: NSImage?
    public var totalBytes: UInt64
    public var isSimulated: Bool

    public init(
        id: String = "outgoing-airdrop-\(UUID().uuidString)",
        fileURLs: [URL],
        phase: AirDropOutgoingPhase,
        recipients: [AirDropDiscoveredRecipient] = [],
        previewImage: NSImage? = nil,
        totalBytes: UInt64 = 0,
        isSimulated: Bool = false
    ) {
        self.id = id
        self.fileURLs = fileURLs
        self.phase = phase
        self.recipients = recipients
        self.previewImage = previewImage
        self.totalBytes = totalBytes
        self.isSimulated = isSimulated
    }

    public static func == (lhs: AirDropOutgoingSession, rhs: AirDropOutgoingSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.fileURLs == rhs.fileURLs &&
        lhs.phase == rhs.phase &&
        lhs.recipients == rhs.recipients &&
        lhs.totalBytes == rhs.totalBytes &&
        lhs.isSimulated == rhs.isSimulated
    }

    public var itemTitle: String {
        if fileURLs.isEmpty {
            return "Drop Files to AirDrop"
        } else if fileURLs.count == 1 {
            return fileURLs[0].lastPathComponent
        } else {
            return "\(fileURLs.count) Files"
        }
    }

    public var itemSubtitle: String {
        switch phase {
        case .dropzoneHover:
            return "Release to stage files in Island"
        case .selectingRecipient:
            let sizeText = Self.formatByteCount(totalBytes)
            if fileURLs.count == 1 {
                return sizeText.isEmpty ? "Choose a nearby device" : "\(sizeText) • Choose a nearby device"
            } else {
                let firstNames = fileURLs.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
                return sizeText.isEmpty ? firstNames : "\(sizeText) • \(firstNames)"
            }
        case .sending(let recipient):
            return "Sending to \(recipient)…"
        case .completed(let recipient):
            return "Sent to \(recipient)"
        }
    }

    public var compactWingBadgeText: String {
        switch phase {
        case .dropzoneHover:
            return "Drop"
        case .selectingRecipient:
            let count = max(1, fileURLs.count)
            return count == 1 ? "1 File" : "\(count) Files"
        case .sending:
            return "Sending"
        case .completed:
            return "Sent"
        }
    }

    public static func formatByteCount(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Manages outgoing AirDrop file staging, `SFAirDropBrowser` nearby recipient discovery,
/// and direct `SFAirDropNode` transfer initiation from inside the Dynamic Island.
@MainActor
public final class AirDropSenderService: NSObject, ObservableObject {
    @Published public private(set) var activeSession: AirDropOutgoingSession?

    public var onSessionUpdated: ((AirDropOutgoingSession?) -> Void)?

    private var sharingFrameworkHandle: UnsafeMutableRawPointer?
    private var bridgeDylibHandle: UnsafeMutableRawPointer?
    private var airDropBrowser: NSObject?
    private var liveNodesByID: [String: NSObject] = [:]
    private var activeSendingNode: NSObject?
    private var sendTransitionTask: Task<Void, Never>?

    public override init() {
        super.init()
    }

    // MARK: - 1. Drag Hover & File Drop Staging

    public func setDropzoneHoverActive(_ active: Bool) {
        if active {
            // If we already have staged files, keep the existing session open so dropping more files appends to it
            if activeSession != nil {
                return
            }
            let session = AirDropOutgoingSession(
                id: "outgoing-dropzone-hover",
                fileURLs: [],
                phase: .dropzoneHover
            )
            updateSession(session)
        } else {
            if activeSession?.phase == .dropzoneHover {
                updateSession(nil)
            }
        }
    }

    public func stageDroppedFiles(_ urls: [URL]) {
        let validURLs = urls.filter { $0.isFileURL }
        guard !validURLs.isEmpty else {
            if activeSession?.phase == .dropzoneHover {
                updateSession(nil)
            }
            return
        }

        sendTransitionTask?.cancel()

        // Merge with existing staged files if the user drops additional files onto an already-staged shelf
        var combinedURLs: [URL] = []
        if let existing = activeSession, existing.phase == .selectingRecipient, !existing.isSimulated {
            combinedURLs = existing.fileURLs
        }
        for url in validURLs where !combinedURLs.contains(url) {
            combinedURLs.append(url)
        }

        let totalBytes = Self.computeTotalBytes(for: combinedURLs)
        let preview = Self.previewImage(for: combinedURLs.first)
        let existingRecipients = (activeSession?.isSimulated == false) ? (activeSession?.recipients ?? []) : []

        let session = AirDropOutgoingSession(
            id: (activeSession?.phase == .selectingRecipient && activeSession?.isSimulated == false)
                ? activeSession!.id
                : "outgoing-airdrop-\(UUID().uuidString)",
            fileURLs: combinedURLs,
            phase: .selectingRecipient,
            recipients: existingRecipients,
            previewImage: preview,
            totalBytes: totalBytes,
            isSimulated: false
        )
        updateSession(session)
        startBrowserDiscovery(for: combinedURLs)
    }

    // MARK: - 2. Sending to a Discovered Recipient

    public func sendToRecipient(_ recipient: AirDropDiscoveredRecipient) {
        guard var session = activeSession, !session.fileURLs.isEmpty else { return }
        sendTransitionTask?.cancel()

        if session.isSimulated || recipient.isSimulated {
            session.phase = .sending(recipientName: recipient.displayName)
            updateSession(session)

            let sessionID = session.id
            let targetName = recipient.displayName
            sendTransitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard !Task.isCancelled, let self,
                      var current = self.activeSession,
                      current.id == sessionID else { return }
                current.phase = .completed(recipientName: targetName)
                self.updateSession(current)
            }
            return
        }

        guard let node = liveNodesByID[recipient.id] else {
            return
        }

        activeSendingNode = node
        let started = invokeNodeStartSend(node: node, urls: session.fileURLs, description: session.itemTitle, preview: session.previewImage)
        guard started else {
            return
        }

        session.phase = .sending(recipientName: recipient.displayName)
        updateSession(session)

        let sessionID = session.id
        let targetName = recipient.displayName
        sendTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, let self,
                  var current = self.activeSession,
                  current.id == sessionID else { return }
            current.phase = .completed(recipientName: targetName)
            self.updateSession(current)
        }
    }

    public func cancelOutgoingSession() {
        sendTransitionTask?.cancel()
        sendTransitionTask = nil

        if let sendingNode = activeSendingNode {
            _ = invokeNodeCancelSend(node: sendingNode)
            activeSendingNode = nil
        }

        stopBrowserDiscovery()
        updateSession(nil)
    }

    // MARK: - 3. Interactive Simulation Helper

    public func simulateOutgoingFileDrop() {
        sendTransitionTask?.cancel()
        stopBrowserDiscovery()

        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let sampleFiles = [
            downloadsDir.appendingPathComponent("Project_Proposal.pdf"),
            downloadsDir.appendingPathComponent("Architecture_Diagram.png")
        ]

        let simulatedRecipients = [
            AirDropDiscoveredRecipient(
                id: "sim-recipient-iphone",
                displayName: "Alex’s iPhone",
                secondaryName: "iPhone 16 Pro",
                deviceModel: "iPhone",
                isSimulated: true
            ),
            AirDropDiscoveredRecipient(
                id: "sim-recipient-ipad",
                displayName: "Sam’s iPad",
                secondaryName: "iPad Pro",
                deviceModel: "iPad",
                isSimulated: true
            ),
            AirDropDiscoveredRecipient(
                id: "sim-recipient-mac",
                displayName: "Studio MacBook",
                secondaryName: "MacBook Pro",
                deviceModel: "MacBook Pro",
                isSimulated: true
            )
        ]

        let session = AirDropOutgoingSession(
            id: "sim-outgoing-\(UUID().uuidString)",
            fileURLs: sampleFiles,
            phase: .selectingRecipient,
            recipients: simulatedRecipients,
            previewImage: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "Files"),
            totalBytes: 4_820_000,
            isSimulated: true
        )
        updateSession(session)
    }

    // MARK: - 4. `SFAirDropBrowser` & `SFAirDropNode` Runtime Bridge

    private func startBrowserDiscovery(for urls: [URL]) {
        stopBrowserDiscovery()

        if sharingFrameworkHandle == nil {
            sharingFrameworkHandle = dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_LAZY)
        }

        guard let browserClass = NSClassFromString("SFAirDropBrowser") as? NSObject.Type else {
            IslandLogger.system.error("SFAirDropBrowser class unavailable in Sharing.framework")
            return
        }

        let browser = browserClass.init()
        let sessionID = UUID().uuidString
        browser.setValue(sessionID, forKey: "sessionID")
        browser.setValue(urls, forKey: "urlsBeingShared")
        browser.setValue(self, forKey: "delegate")

        let startSel = NSSelectorFromString("start")
        if browser.responds(to: startSel) {
            _ = browser.perform(startSel)
        }

        self.airDropBrowser = browser
        refreshDiscoveredPeople(from: browser)
    }

    private func stopBrowserDiscovery() {
        if let browser = airDropBrowser {
            browser.setValue(nil, forKey: "delegate")
            let stopSel = NSSelectorFromString("stop")
            if browser.responds(to: stopSel) {
                _ = browser.perform(stopSel)
            }
            airDropBrowser = nil
        }
        liveNodesByID.removeAll()
    }

    @objc(browserWillChangePeople:)
    public func browserWillChangePeople(_ browser: AnyObject) {}

    @objc(browserDidChangePeople:)
    public func browserDidChangePeople(_ browser: AnyObject) {
        Task { @MainActor [weak self] in
            guard let self, let browserObj = browser as? NSObject else { return }
            self.refreshDiscoveredPeople(from: browserObj)
        }
    }

    @objc(browser:didInsertPersonAtIndex:)
    public func browser(_ browser: AnyObject, didInsertPersonAtIndex index: Int) {
        Task { @MainActor [weak self] in
            guard let self, let browserObj = browser as? NSObject else { return }
            self.refreshDiscoveredPeople(from: browserObj)
        }
    }

    @objc(browser:didDeletePersonAtIndex:)
    public func browser(_ browser: AnyObject, didDeletePersonAtIndex index: Int) {
        Task { @MainActor [weak self] in
            guard let self, let browserObj = browser as? NSObject else { return }
            self.refreshDiscoveredPeople(from: browserObj)
        }
    }

    private func refreshDiscoveredPeople(from browser: NSObject) {
        guard var current = activeSession, !current.isSimulated else { return }
        let rawPeople = (browser.value(forKey: "people") as? [NSObject]) ?? []

        var discovered: [AirDropDiscoveredRecipient] = []
        var updatedMap: [String: NSObject] = [:]

        for node in rawPeople {
            let isDisabled = (node.value(forKey: "isDisabled") as? Bool) ?? false
            if isDisabled { continue }

            let nodeID = (node.value(forKey: "nodeIdentifier") as? String)
                ?? (node.value(forKey: "endpointUUID") as? UUID)?.uuidString
                ?? String(ObjectIdentifier(node).hashValue)

            let displayName = (node.value(forKey: "displayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let realName = (node.value(forKey: "realName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let secondaryName = (node.value(forKey: "secondaryName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (node.value(forKey: "model") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Device"

            let resolvedName = !displayName.isEmpty ? displayName : (!realName.isEmpty ? realName : model)
            let icon = copyNodeDisplayIcon(node: node)

            updatedMap[nodeID] = node
            discovered.append(
                AirDropDiscoveredRecipient(
                    id: nodeID,
                    displayName: resolvedName,
                    secondaryName: secondaryName,
                    deviceModel: model,
                    avatarIcon: icon,
                    isSimulated: false
                )
            )
        }

        liveNodesByID = updatedMap
        if current.recipients != discovered {
            current.recipients = discovered
            updateSession(current)
        }
    }

    // MARK: - 5. Native C Helpers (`libIslandMediaRemoteBridge.dylib`)

    private func ensureBridgeDylibLoaded() -> UnsafeMutableRawPointer? {
        if let handle = bridgeDylibHandle {
            return handle
        }
        let candidates: [String] = [
            Bundle.main.path(forResource: "libIslandMediaRemoteBridge", ofType: "dylib"),
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/libIslandMediaRemoteBridge.dylib").path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/libIslandMediaRemoteBridge.dylib").path
        ].compactMap { $0 }

        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let handle = dlopen(path, RTLD_LAZY) else {
            return nil
        }
        bridgeDylibHandle = handle
        return handle
    }

    private func copyNodeDisplayIcon(node: NSObject) -> NSImage? {
        guard let handle = ensureBridgeDylibLoaded(),
              let sym = dlsym(handle, "island_airdrop_node_copy_display_icon") else {
            return nil
        }
        typealias CopyIconFn = @convention(c) (AnyObject) -> Unmanaged<CGImage>?
        let fn = unsafeBitCast(sym, to: CopyIconFn.self)
        guard let unmanaged = fn(node) else { return nil }
        let cgImg = unmanaged.takeRetainedValue()
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }

    private func invokeNodeStartSend(node: NSObject, urls: [URL], description: String, preview: NSImage?) -> Bool {
        guard let handle = ensureBridgeDylibLoaded(),
              let sym = dlsym(handle, "island_airdrop_node_start_send") else {
            return false
        }
        typealias StartSendFn = @convention(c) (AnyObject, NSString, NSString, NSArray, NSString, CGImage?) -> Int32
        let fn = unsafeBitCast(sym, to: StartSendFn.self)
        let bundleID = (Bundle.main.bundleIdentifier ?? "com.island.app") as NSString
        let sessionID = ((airDropBrowser?.value(forKey: "sessionID") as? String) ?? UUID().uuidString) as NSString
        var proposedRect = NSRect(origin: .zero, size: NSSize(width: 64, height: 64))
        let cgPreview = preview?.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)

        return fn(node, bundleID, sessionID, urls as NSArray, description as NSString, cgPreview) == 1
    }

    private func invokeNodeCancelSend(node: NSObject) -> Bool {
        guard let handle = ensureBridgeDylibLoaded(),
              let sym = dlsym(handle, "island_airdrop_node_cancel_send") else {
            return false
        }
        typealias CancelSendFn = @convention(c) (AnyObject) -> Int32
        let fn = unsafeBitCast(sym, to: CancelSendFn.self)
        return fn(node) == 1
    }

    // MARK: - 6. File Metadata Helpers

    private static func computeTotalBytes(for urls: [URL]) -> UInt64 {
        var total: UInt64 = 0
        let fm = FileManager.default
        for url in urls {
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) {
                total += size
            }
        }
        return total
    }

    private static func previewImage(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "bmp"]
        if imageExtensions.contains(url.pathExtension.lowercased()),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "doc.fill", accessibilityDescription: url.lastPathComponent)
    }

    private func updateSession(_ session: AirDropOutgoingSession?) {
        activeSession = session
        onSessionUpdated?(session)
    }
}
