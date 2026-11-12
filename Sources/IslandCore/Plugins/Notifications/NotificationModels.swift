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

    public init(
        appName: String,
        kind: IslandNotificationKind,
        sender: String,
        title: String? = nil,
        channel: String? = nil,
        body: String,
        canReply: Bool = false
    ) {
        self.appName = appName
        self.kind = kind
        self.sender = sender
        self.title = title
        self.channel = channel
        self.body = body
        self.canReply = canReply
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

/// In-memory notification record kept while "Keep notifications until dismissed" is enabled.
public struct NotificationHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let notification: IslandNotification
    public let receivedAt: Date

    public init(id: String = UUID().uuidString, notification: IslandNotification, receivedAt: Date = Date()) {
        self.id = id
        self.notification = notification
        self.receivedAt = receivedAt
    }
}
