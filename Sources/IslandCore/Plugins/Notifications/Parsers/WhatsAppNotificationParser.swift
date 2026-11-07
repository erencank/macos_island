import Foundation

public struct WhatsAppNotificationParser: AppNotificationParser {
    public static let appName = "WhatsApp"
    public var appName: String { Self.appName }
    private static let callMarkers = [
        "incoming voice call", "incoming video call", "is calling",
        "calling you", "inkomende spraakoproep", "inkomende video-oproep"
    ]
    private static let callButtonMarkers = ["accept", "decline", "answer", "reject", "accepteren", "weiger"]

    public init() {}

    /// WhatsApp banners expose `[app, sender, groupName, message]` for group chats
    /// and `[app, sender, message]` for direct 1-on-1 chats.
    public func parse(_ banner: RawBanner) -> IslandNotification? {
        guard BannerTextCleaner.mentionsApp(banner, appName: appName) else { return nil }
        let content = BannerTextCleaner.contentTexts(of: banner, appName: appName)
        guard let sender = content.first else { return nil }

        let joined = content.joined(separator: " ").lowercased()
        let hasCallButtons = banner.buttons.contains { button in
            Self.callButtonMarkers.contains { button.title.lowercased().contains($0) }
        }
        if hasCallButtons || Self.callMarkers.contains(where: { joined.contains($0) }) {
            return IslandNotification(
                appName: appName,
                kind: .incomingCall,
                sender: sender,
                channel: nil,
                body: "Incoming call"
            )
        }

        if content.count >= 3 {
            let group = content[1]
            let body = content[content.count - 1]
            let channel = group.caseInsensitiveCompare(sender) == .orderedSame ? nil : group
            return IslandNotification(
                appName: appName,
                kind: .message,
                sender: sender,
                channel: channel,
                body: body
            )
        }

        let body = content.count > 1 ? content[content.count - 1] : ""
        return IslandNotification(
            appName: appName,
            kind: .message,
            sender: sender,
            channel: nil,
            body: body
        )
    }
}
