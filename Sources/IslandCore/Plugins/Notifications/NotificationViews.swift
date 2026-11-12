import AppKit
import SwiftUI

enum NotificationAppIcon {
    @MainActor
    static func image(forAppNamed name: String) -> NSImage? {
        let target = BannerTextCleaner.trim(name)
        if let icon = NSWorkspace.shared.runningApplications.first(where: {
            guard let localized = $0.localizedName else { return false }
            return BannerTextCleaner.trim(localized).caseInsensitiveCompare(target) == .orderedSame
        })?.icon {
            return icon
        }

        let appPath = "/Applications/\(target).app"
        if FileManager.default.fileExists(atPath: appPath) {
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        return nil
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
    public let entryID: String?
    @FocusState private var isFieldFocused: Bool

    public init(plugin: NotificationBridgePlugin, notification: IslandNotification, entryID: String? = nil) {
        self.plugin = plugin
        self.notification = notification
        self.entryID = entryID
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                NotificationCompactLeadingView(notification: notification)
                    .scaleEffect(1.9)
                    .frame(width: 40, height: 40)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(notification.appName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if plugin.keepUntilDismissed && !plugin.isReplying && !plugin.history.isEmpty {
                            historyPager
                        }
                    }

                    Text(notification.headline)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    bodyText
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
            if plugin.isReplying {
                replyComposerRow
            } else {
                actionRow
            }
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
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !notification.body.isEmpty {
            Text(notification.body)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.leading)
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
            HStack(spacing: 8) {
                NotificationActionButton(title: "Dismiss", symbolName: "xmark", fill: .white.opacity(0.12), text: .white) {
                    plugin.dismissCurrent()
                }
                if plugin.canReply(to: notification, entryID: entryID) {
                    NotificationActionButton(title: "Reply", symbolName: "arrowshape.turn.up.left.fill", fill: .white.opacity(0.2), text: .white) {
                        plugin.beginReply()
                    }
                }
                NotificationActionButton(title: "Open", symbolName: "arrow.up.right.square.fill", fill: .white, text: .black) {
                    plugin.openCurrent()
                }
            }
        }
    }

    @ViewBuilder
    private var historyPager: some View {
        let total = plugin.history.count
        let currentIndex = plugin.isBrowsingHistory ? plugin.selectedHistoryIndex : 0
        let canGoNewer = plugin.isBrowsingHistory && currentIndex > 0
        let canGoOlder = currentIndex + 1 < total

        HStack(spacing: 6) {
            if total > 1 {
                HStack(spacing: 4) {
                    Button {
                        plugin.showPreviousNotification()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.white.opacity(canGoNewer ? 0.85 : 0.25))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGoNewer)

                    Text("\(currentIndex + 1)/\(total)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))

                    Button {
                        plugin.showNextNotification()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.white.opacity(canGoOlder ? 0.85 : 0.25))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGoOlder)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.1)))

                Button {
                    plugin.clearAllHistory()
                } label: {
                    Text("Clear")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            } else if plugin.isBrowsingHistory {
                Button {
                    plugin.closeHistory()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Back")
            }
        }
    }

    @ViewBuilder
    private var replyComposerRow: some View {
        HStack(spacing: 8) {
            Button(action: { plugin.cancelReply() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Cancel reply")

            TextField("Reply to \(notification.sender)…", text: $plugin.replyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .focused($isFieldFocused)
                .onSubmit {
                    plugin.submitReply()
                }

            Button(action: { plugin.submitReply() }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(canSubmitReply ? .black : .white.opacity(0.35))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(canSubmitReply ? Color.white : Color.white.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitReply)
        }
        .onAppear {
            isFieldFocused = true
        }
    }

    private var canSubmitReply: Bool {
        !plugin.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !plugin.isSendingReply
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
