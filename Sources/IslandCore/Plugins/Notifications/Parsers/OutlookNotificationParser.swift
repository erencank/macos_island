import Foundation

public struct OutlookNotificationParser: AppNotificationParser {
    public static let appName = "Microsoft Outlook"
    public var appName: String { Self.appName }
    private static let appAliases = ["microsoft outlook", "outlook"]
    private static let calendarMarkers = ["starts in", "starting in"]

    public init() {}

    /// Outlook banners expose `[app, subject, sender, preview]`.
    public func parse(_ banner: RawBanner) -> IslandNotification? {
        guard let alias = Self.appAliases.first(where: { BannerTextCleaner.mentionsApp(banner, appName: $0) }) else {
            return nil
        }
        let content = BannerTextCleaner.contentTexts(of: banner, appName: alias)
        guard content.count >= 2 else { return nil }

        let joined = content.joined(separator: " ").lowercased()
        if banner.buttons.contains(where: { $0.title.lowercased().contains("snooze") })
            || Self.calendarMarkers.contains(where: { joined.contains($0) }) {
            return nil
        }

        let subject = content[0]
        let sender = content[1]
        let preview = content.count > 2 ? content[content.count - 1] : ""
        return IslandNotification(
            appName: appName,
            kind: .email,
            sender: sender,
            title: subject,
            channel: nil,
            body: preview,
            canReply: false
        )
    }
}
