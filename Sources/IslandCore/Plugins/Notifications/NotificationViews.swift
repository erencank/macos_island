import AppKit
import SwiftUI

enum NotificationAppIcon {
    @MainActor
    static func image(forAppNamed name: String) -> NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }?
            .icon
    }
}

public struct NotificationCompactLeadingView: View {
    public let notification: IslandNotification

    public init(notification: IslandNotification) {
        self.notification = notification
    }

    public var body: some View {
        if let icon = NotificationAppIcon.image(forAppNamed: notification.appName) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: notification.kind == .email ? "envelope.fill" : "bell.badge.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

public struct NotificationCompactTrailingView: View {
    public let notification: IslandNotification

    public init(notification: IslandNotification) {
        self.notification = notification
    }

    public var body: some View {
        switch notification.kind {
        case .incomingCall:
            Image(systemName: "phone.fill")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(.green)
                .symbolEffect(.pulse)
        case .message, .email:
            if let subtext = notification.subtext, !subtext.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(notification.headline)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(subtext)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(notification.headline)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

public struct NotificationExpandedCardView: View {
    @ObservedObject public var plugin: NotificationBridgePlugin
    public let notification: IslandNotification

    public init(plugin: NotificationBridgePlugin, notification: IslandNotification) {
        self.plugin = plugin
        self.notification = notification
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                NotificationCompactLeadingView(notification: notification)
                    .scaleEffect(1.9)
                    .frame(width: 40, height: 40)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.appName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                    Text(notification.headline)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    bodyText
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
            actionRow
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var bodyText: some View {
        if notification.kind == .email {
            let subject = (notification.title?.isEmpty == false)
                ? notification.title!
                : (notification.body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
            if !subject.isEmpty {
                Text(subject)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
            }
            let preview: String = {
                if notification.title?.isEmpty == false {
                    if notification.body == subject { return "" }
                    if notification.body.hasPrefix(subject + "\n") {
                        return String(notification.body.dropFirst(subject.count + 1))
                    }
                    return notification.body
                }
                return notification.body.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            }()
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !notification.body.isEmpty {
            Text(notification.body)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch notification.kind {
        case .incomingCall:
            HStack(spacing: 10) {
                NotificationActionButton(title: "Decline", symbolName: "phone.down.fill", fill: .red, text: .white) {
                    plugin.declineCurrent()
                }
                NotificationActionButton(title: "Accept", symbolName: "phone.fill", fill: .green, text: .black) {
                    plugin.acceptCurrent()
                }
            }
        case .message, .email:
            HStack(spacing: 10) {
                NotificationActionButton(title: "Dismiss", symbolName: "xmark", fill: .white.opacity(0.12), text: .white) {
                    plugin.dismissCurrent()
                }
                NotificationActionButton(title: "Open", symbolName: "arrow.up.right.square.fill", fill: .white, text: .black) {
                    plugin.openCurrent()
                }
            }
        }
    }
}

private struct NotificationActionButton: View {
    let title: String
    let symbolName: String
    let fill: Color
    let text: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundColor(text)
            .padding(.vertical, 8.5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
    }
}
