import Foundation

/// A button exposed by a system notification banner (e.g. "Accept", "Decline", "Reply").
public struct BannerButton {
    public let title: String
    public let press: () -> Bool

    public init(title: String, press: @escaping () -> Bool) {
        self.title = title
        self.press = press
    }
}

/// Raw, app-agnostic snapshot of a Notification Center banner read through Accessibility.
public struct RawBanner {
    public let texts: [String]
    public let buttons: [BannerButton]
    public let canReply: Bool
    public let isBannerAlive: () -> Bool
    public let pressBanner: () -> Bool
    public let hideBanner: () -> Void
    public let beginReply: () -> Bool
    public let sendReply: (String) -> Bool

    public init(
        texts: [String],
        buttons: [BannerButton] = [],
        canReply: Bool = false,
        isBannerAlive: (() -> Bool)? = nil,
        pressBanner: @escaping () -> Bool = { false },
        hideBanner: @escaping () -> Void = {},
        beginReply: @escaping () -> Bool = { false },
        sendReply: @escaping (String) -> Bool = { _ in false }
    ) {
        self.texts = texts
        self.buttons = buttons
        self.canReply = canReply
        self.isBannerAlive = isBannerAlive ?? { canReply }
        self.pressBanner = pressBanner
        self.hideBanner = hideBanner
        self.beginReply = beginReply
        self.sendReply = sendReply
    }

    /// Stable identity used to tell a new banner from one that was already presented.
    public var key: String { texts.joined(separator: "\u{1F}") }
}

public enum IslandNotificationKind: Equatable, Sendable {
    case message
    case email
    case incomingCall
}

/// Parsed, display-ready notification.
public struct IslandNotification: Equatable, Sendable {
    public let appName: String
    public let kind: IslandNotificationKind
    public let sender: String
    public let title: String?
    public let channel: String?
    public let body: String
    public var canReply: Bool
    public let threadKey: String?

    public init(
        appName: String,
        kind: IslandNotificationKind,
        sender: String,
        title: String? = nil,
        channel: String? = nil,
        body: String,
        canReply: Bool = false,
        threadKey: String? = nil
    ) {
        self.appName = appName
        self.kind = kind
        self.sender = sender
        self.title = title
        self.channel = channel
        self.body = body
        self.canReply = canReply
        self.threadKey = threadKey
    }

    public static func messageThreadKey(appName: String, sender: String, channel: String?) -> String? {
        if let channel = channel?.trimmingCharacters(in: .whitespacesAndNewlines), !channel.isEmpty {
            return "\(appName.lowercased())|channel|\(channel.lowercased())"
        }
        let cleanSender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSender.isEmpty else { return nil }
        return "\(appName.lowercased())|dm|\(cleanSender.lowercased())"
    }

    public var headline: String {
        guard let channel, !channel.isEmpty else { return sender }
        return sender.isEmpty ? channel : "\(sender) · \(channel)"
    }

    public var subtext: String? {
        if kind == .email {
            if let title, !title.isEmpty { return title }
            let firstLine = body.split(separator: "\n", maxSplits: 1).first.map(String.init)
            return firstLine?.isEmpty == false ? firstLine : nil
        }
        if kind == .incomingCall { return nil }
        let firstLine = body.split(separator: "\n", maxSplits: 1).first.map(String.init)
        return firstLine?.isEmpty == false ? firstLine : nil
    }
}

/// Single message within a grouped chat notification thread.
public struct NotificationThreadMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String
    public let body: String
    public let receivedAt: Date

    public init(id: String = UUID().uuidString, sender: String, body: String, receivedAt: Date = Date()) {
        self.id = id
        self.sender = sender
        self.body = body
        self.receivedAt = receivedAt
    }

    public init(notification: IslandNotification, receivedAt: Date = Date()) {
        self.init(sender: notification.sender, body: notification.body, receivedAt: receivedAt)
    }
}

/// In-memory notification record (or grouped thread) kept while "Keep notifications until dismissed" is enabled.
public struct NotificationHistoryEntry: Identifiable, Equatable, Sendable {
    private static let maxMessagesPerThread = 20

    public let id: String
    public let notification: IslandNotification
    public let messages: [NotificationThreadMessage]
    public let receivedAt: Date

    public init(
        id: String = UUID().uuidString,
        notification: IslandNotification,
        messages: [NotificationThreadMessage]? = nil,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.notification = notification
        self.messages = messages ?? [NotificationThreadMessage(notification: notification, receivedAt: receivedAt)]
        self.receivedAt = receivedAt
    }

    public func appending(_ newer: IslandNotification, at date: Date = Date()) -> NotificationHistoryEntry {
        var updated = messages
        updated.append(NotificationThreadMessage(notification: newer, receivedAt: date))
        if updated.count > Self.maxMessagesPerThread {
            updated = Array(updated.suffix(Self.maxMessagesPerThread))
        }
        return NotificationHistoryEntry(id: id, notification: newer, messages: updated, receivedAt: date)
    }
}
