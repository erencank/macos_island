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
    public let pressBanner: () -> Bool
    public let hideBanner: () -> Void

    public init(
        texts: [String],
        buttons: [BannerButton] = [],
        pressBanner: @escaping () -> Bool = { false },
        hideBanner: @escaping () -> Void = {}
    ) {
        self.texts = texts
        self.buttons = buttons
        self.pressBanner = pressBanner
        self.hideBanner = hideBanner
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
    public let channel: String?
    public let body: String

    public init(appName: String, kind: IslandNotificationKind, sender: String, channel: String?, body: String) {
        self.appName = appName
        self.kind = kind
        self.sender = sender
        self.channel = channel
        self.body = body
    }

    /// Text shown in the right wing, e.g. `Alice · #general`.
    public var headline: String {
        guard let channel, !channel.isEmpty else { return sender }
        return sender.isEmpty ? channel : "\(sender) · \(channel)"
    }
}
