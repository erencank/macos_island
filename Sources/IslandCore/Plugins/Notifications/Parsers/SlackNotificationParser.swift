import Foundation

public struct SlackNotificationParser: AppNotificationParser {
    public static let appName = "Slack"
    public var appName: String { Self.appName }

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
        }

        let sender = Self.stripLeadIn(title)
        return IslandNotification(appName: appName, kind: .message, sender: sender, channel: channel, body: body)
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
