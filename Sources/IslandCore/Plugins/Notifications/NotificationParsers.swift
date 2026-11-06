import Foundation

public protocol AppNotificationParser: Sendable {
    var appName: String { get }
    func parse(_ banner: RawBanner) -> IslandNotification?
}

enum BannerTextCleaner {
    private static let timeMarkers: Set<String> = ["now", "nu", "jetzt", "ahora", "maintenant", "yesterday", "gisteren", "gestern", "hier"]
    private static let relativeTimeRegex = try? NSRegularExpression(
        pattern: #"^(?:vor\s+|il y a\s+)?\d+\s*(?:s|m|h|d|min|mins|minute|minutes|hour|hours|sec|secs|uur|minuten|seconden)\s*(?:ago|geleden)?$"#,
        options: .caseInsensitive
    )

    static func isTimeMarker(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if timeMarkers.contains(lowered) { return true }
        guard let regex = relativeTimeRegex else { return false }
        let range = NSRange(lowered.startIndex..., in: lowered)
        return regex.firstMatch(in: lowered, range: range) != nil
    }

    /// Removes combined summary strings (Notification Center often exposes both the joined
    /// description and each individual label), button titles, the app name and timestamps.
    static func contentTexts(of banner: RawBanner, appName: String) -> [String] {
        let buttonTitles = Set(banner.buttons.map { $0.title.lowercased() })
        let candidates = banner.texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !buttonTitles.contains($0.lowercased()) }
            .filter { !isTimeMarker($0) }
            .filter { $0.caseInsensitiveCompare(appName) != .orderedSame }

        return candidates.filter { text in
            let contained = candidates.filter { $0 != text && text.contains($0) }
            return contained.count < 2
        }
    }

    static func mentionsApp(_ banner: RawBanner, appName: String) -> Bool {
        let lowered = appName.lowercased()
        return banner.texts.contains { text in
            let value = text.lowercased()
            return value == lowered || value.hasPrefix(lowered + ",")
        }
    }
}

public struct SlackNotificationParser: AppNotificationParser {
    public let appName = "Slack"

    public init() {}

    public func parse(_ banner: RawBanner) -> IslandNotification? {
        guard BannerTextCleaner.mentionsApp(banner, appName: appName) else { return nil }
        let content = BannerTextCleaner.contentTexts(of: banner, appName: appName)
        guard let first = content.first else { return nil }

        if content.count >= 3 {
            let target = content[1]
            let rawMessage = content[content.count - 1]

            var sender = ""
            var body = rawMessage

            if let colonIndex = rawMessage.firstIndex(of: ":") {
                let candidateSender = String(rawMessage[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let candidateBody = String(rawMessage[rawMessage.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                if !candidateSender.isEmpty, candidateSender.count <= 40, !candidateSender.contains("\n") {
                    sender = candidateSender
                    body = candidateBody
                }
            }

            var channel: String?
            if sender.isEmpty {
                sender = target
                channel = nil
            } else if target.caseInsensitiveCompare(sender) == .orderedSame {
                channel = nil
            } else {
                channel = target.hasPrefix("#") ? target : (target.contains(",") ? target : "#\(target)")
            }

            return IslandNotification(
                appName: appName,
                kind: .message,
                sender: sender,
                channel: channel,
                body: body
            )
        }

        let body = content.count > 1 ? content[content.count - 1] : ""
        var title = first
        var channel: String?

        if let match = Self.channelPattern.firstMatch(in: title) {
            channel = match.channel
            title = match.remainder
        } else if content.count > 2, Self.isChannelLabel(content[1]) {
            channel = content[1]
        }

        let sender = Self.stripLeadIn(title)
        if sender.isEmpty, let channel, content.count > 2 {
            return IslandNotification(appName: appName, kind: .message, sender: content[1], channel: channel, body: body)
        }
        return IslandNotification(appName: appName, kind: .message, sender: sender, channel: channel, body: body)
    }

    private static func isChannelLabel(_ text: String) -> Bool {
        text.hasPrefix("#")
    }

    private static func stripLeadIn(_ title: String) -> String {
        var result = title
        for prefix in ["New message from ", "New message in ", "Message from "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private enum channelPattern {
        static func firstMatch(in title: String) -> (channel: String, remainder: String)? {
            let pattern = #"^(.*?)\s*(?:\(|\bin\s+)?(#[^\s)]+)\)?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let remainderRange = Range(match.range(at: 1), in: title),
                  let channelRange = Range(match.range(at: 2), in: title) else {
                return nil
            }
            return (String(title[channelRange]), String(title[remainderRange]))
        }
    }
}

public struct TeamsNotificationParser: AppNotificationParser {
    public let appName = "Microsoft Teams"
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

public struct OutlookNotificationParser: AppNotificationParser {
    public let appName = "Microsoft Outlook"
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
        let body = preview.isEmpty ? subject : "\(subject)\n\(preview)"
        return IslandNotification(
            appName: appName,
            kind: .email,
            sender: sender,
            title: subject,
            channel: nil,
            body: body
        )
    }
}

/// Fallback for apps without a dedicated parser. Must be opted in by the user.
public struct GenericNotificationParser: Sendable {
    public init() {}

    public func parse(_ banner: RawBanner, appName: String) -> IslandNotification? {
        let content = BannerTextCleaner.contentTexts(of: banner, appName: appName)
        guard let first = content.first else { return nil }
        let body = content.count > 1 ? content[content.count - 1] : ""
        return IslandNotification(appName: appName, kind: .message, sender: first, channel: nil, body: body)
    }
}

public struct NotificationParserSet: Sendable {
    private let appParsers: [any AppNotificationParser]

    public init(appParsers: [any AppNotificationParser] = [SlackNotificationParser(), TeamsNotificationParser(), OutlookNotificationParser()]) {
        self.appParsers = appParsers
    }

    public var knownAppNames: [String] { appParsers.map(\.appName) }

    public func parse(_ banner: RawBanner) -> IslandNotification? {
        for parser in appParsers {
            if let notification = parser.parse(banner) { return notification }
        }
        return nil
    }

    /// First text of a banner is the app name on macOS; used by the generic fallback.
    public func parseGeneric(_ banner: RawBanner) -> IslandNotification? {
        guard let appName = banner.texts.first?
            .split(separator: ",", maxSplits: 1).first
            .map({ String($0).trimmingCharacters(in: .whitespaces) }),
            !appName.isEmpty else { return nil }
        return GenericNotificationParser().parse(banner, appName: appName)
    }
}
