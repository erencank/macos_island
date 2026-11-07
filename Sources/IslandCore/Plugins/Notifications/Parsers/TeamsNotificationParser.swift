import Foundation

public struct TeamsNotificationParser: AppNotificationParser {
    public static let appName = "Microsoft Teams"
    public var appName: String { Self.appName }
    private static let appAliases = ["microsoft teams", "teams"]
    private static let callMarkers = ["is calling", "incoming call", "calling you", "calling…", "calling..."]
    private static let callButtonMarkers = ["accept", "decline", "answer", "reject"]

    public init() {}

    public func parse(_ banner: RawBanner) -> IslandNotification? {
        guard let alias = Self.appAliases.first(where: { BannerTextCleaner.mentionsApp(banner, appName: $0) }) else {
            return nil
        }
        let content = BannerTextCleaner.contentTexts(of: banner, appName: alias)
            .filter { $0.caseInsensitiveCompare(appName) != .orderedSame }
        guard let first = content.first else { return nil }

        let joined = content.joined(separator: " ").lowercased()
        let hasCallButtons = banner.buttons.contains { button in
            Self.callButtonMarkers.contains { button.title.lowercased().contains($0) }
        }
        let isCall = hasCallButtons || Self.callMarkers.contains { joined.contains($0) }

        if isCall {
            let caller = Self.callerName(from: first)
            return IslandNotification(appName: appName, kind: .incomingCall, sender: caller, channel: nil, body: "Incoming call")
        }
        let body = content.count > 1 ? content[content.count - 1] : ""
        return IslandNotification(appName: appName, kind: .message, sender: first, channel: nil, body: body)
    }

    private static func callerName(from text: String) -> String {
        for marker in [" is calling", " calling"] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }
}
