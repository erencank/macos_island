import Foundation

public protocol AppNotificationParser: Sendable {
    var appName: String { get }
    func parse(_ banner: RawBanner) -> IslandNotification?
}

enum BannerTextCleaner {
    private static let trimCharacterSet: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{200E}\u{200F}\u{200B}\u{200C}\u{200D}\u{FEFF}")
        return set
    }()

    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: trimCharacterSet)
    }

    private static let timeMarkers: Set<String> = ["now", "nu", "jetzt", "ahora", "maintenant", "yesterday", "gisteren", "gestern", "hier"]
    private static let relativeTimeRegex = try? NSRegularExpression(
        pattern: #"^(?:vor\s+|il y a\s+)?\d+\s*(?:s|sec|secs|sek|seks|m|min|mins|minute|minutes|minuten|h|hr|hrs|hour|hours|uur|stunde|stunden|d|day|days|dag|dagen|tag|tage|w|wk|wks|week|weken|woche|mo|yr|y|jaar|jahre?)\.?\s*(?:ago|geleden|vor|her)?$"#,
        options: .caseInsensitive
    )
    private static let clockTimeRegex = try? NSRegularExpression(
        pattern: #"^(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:am|pm|vm|nm))?$"#,
        options: .caseInsensitive
    )

    private static let trayControlTexts: Set<String> = [
        "show details", "show less", "details weergeven", "minder weergeven",
        "details einblenden", "weniger anzeigen", "afficher les détails", "afficher moins",
        "ver detalles", "mostrar menos", "mostra dettagli", "mostra meno",
        "clear all", "wis alles", "alle löschen", "tout effacer", "borrar todo", "cancella tutto"
    ]

    static func isRelativeTimeMarker(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "yesterday" || lowered == "gisteren" || lowered == "gestern" || lowered == "hier" { return true }
        guard let regex = relativeTimeRegex else { return false }
        let range = NSRange(lowered.startIndex..., in: lowered)
        return regex.firstMatch(in: lowered, range: range) != nil
    }

    static func isClockTimeMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let regex = clockTimeRegex else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return regex.firstMatch(in: trimmed, range: range) != nil
    }

    static func isTrayText(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trayControlTexts.contains(lowered) { return true }
        if lowered == "notification centre" || lowered == "notification center" || lowered == "berichtencentrum" || lowered == "mitteilungszentrale" || lowered == "centre de notifications" {
            return true
        }
        return false
    }

    static func isTrayItem(_ banner: RawBanner) -> Bool {
        if banner.texts.contains(where: { isRelativeTimeMarker($0) || isClockTimeMarker($0) || isTrayText($0) }) {
            return true
        }
        if banner.buttons.contains(where: {
            let t = $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trayControlTexts.contains(t)
        }) {
            return true
        }
        return false
    }

    static func isTimeMarker(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if timeMarkers.contains(lowered) { return true }
        return isRelativeTimeMarker(lowered) || isClockTimeMarker(lowered)
    }

    /// Removes combined summary strings (Notification Center often exposes both the joined
    /// description and each individual label), button titles, the app name and timestamps.
    static func contentTexts(of banner: RawBanner, appName: String) -> [String] {
        let buttonTitles = Set(banner.buttons.map { trim($0.title).lowercased() })
        let candidates = banner.texts
            .map { trim($0) }
            .filter { !$0.isEmpty }
            .filter { !buttonTitles.contains($0.lowercased()) }
            .filter { !isTimeMarker($0) }
            .filter { $0.caseInsensitiveCompare(appName) != .orderedSame }

        let loweredApp = trim(appName).lowercased()
        return candidates.filter { text in
            guard text.lowercased().hasPrefix(loweredApp) else { return true }
            let contained = candidates.filter { $0 != text && text.contains($0) }
            return contained.count < 2
        }
    }

    static func mentionsApp(_ banner: RawBanner, appName: String) -> Bool {
        let lowered = trim(appName).lowercased()
        return banner.texts.contains { text in
            let value = trim(text).lowercased()
            if value == lowered || value.hasPrefix(lowered + ",") || value.hasPrefix(lowered + " ") || value.hasPrefix(lowered + ":") || value.hasPrefix(lowered + " -") || value.hasPrefix(lowered + " –") {
                return true
            }
            let segments = value.components(separatedBy: CharacterSet(charactersIn: ",-–—:"))
                .map { trim($0) }
            return segments.contains(lowered)
        }
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

    public init(
        appParsers: [any AppNotificationParser] = [
            SlackNotificationParser(),
            TeamsNotificationParser(),
            OutlookNotificationParser(),
            WhatsAppNotificationParser()
        ]
    ) {
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
            .map({ BannerTextCleaner.trim(String($0)) }),
            !appName.isEmpty else { return nil }
        return GenericNotificationParser().parse(banner, appName: appName)
    }
}
