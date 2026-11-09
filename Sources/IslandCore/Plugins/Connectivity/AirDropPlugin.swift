import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Compact Wings Views for Active / Completed AirDrop

public struct AirDropCompactLeadingView: View {
    public let phase: AirDropTransferPhase

    public init(phase: AirDropTransferPhase) {
        self.phase = phase
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.18))
                .frame(width: 20, height: 20)

            Image(systemName: "airplayaudio")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.cyan)
                .symbolEffect(.pulse, isActive: phase == .transferring)
        }
    }
}

public struct AirDropCompactTrailingView: View {
    public let session: AirDropTransferSession

    public init(session: AirDropTransferSession) {
        self.session = session
    }

    public var body: some View {
        switch session.phase {
        case .awaitingConfirmation:
            Text("AirDrop")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundColor(.cyan)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

        case .awaitingVerificationCode:
            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.cyan)
                Text(session.itemTitle)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

        case .transferring:
            if session.isIndeterminateProgress {
                HStack(spacing: 5) {
                    AirDropIndeterminateSpinnerView(size: 12.5, lineWidth: 2.0)
                    Text("Saving")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                let pct = Int((session.progress * 100).rounded())
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.22), lineWidth: 2.0)
                            .frame(width: 12, height: 12)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.08, session.progress)))
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 12, height: 12)
                    }

                    Text("\(pct)%")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.green)
                Text("Saved")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

        case .declined, .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(.red)
        }
    }
}

// MARK: - Expanded Interactive AirDrop Card View

public struct AirDropExpandedCardView: View {
    @ObservedObject public var plugin: AirDropPlugin
    public let session: AirDropTransferSession

    public init(plugin: AirDropPlugin, session: AirDropTransferSession) {
        self.plugin = plugin
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Top Row: Preview / Icon + Sender & Item Info + AirDrop Badge
            HStack(spacing: 12) {
                previewThumbnail

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: isCodeSession ? "key.fill" : "airplayaudio")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.cyan)
                        Text(isCodeSession ? "AirDrop Code • \(session.senderName)" : session.senderName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.cyan)
                            .lineLimit(1)
                    }

                    if isCodeSession {
                        Text(formattedVerificationCode)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .tracking(2.5)
                            .foregroundColor(.white)
                            .lineLimit(1)
                    } else {
                        Text(session.itemTitle)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }

                    Text(session.itemSubtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer()
            }

            // Middle Row: Progress Bar when transferring
            if session.phase == .transferring {
                if session.isIndeterminateProgress {
                    AirDropIndeterminateProgressBarView()
                        .frame(height: 12)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.16))
                                .frame(height: 6)

                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan, Color(red: 0.25, green: 0.88, blue: 0.72)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: max(10, min(geo.size.width, geo.size.width * CGFloat(session.progress))),
                                    height: 6
                                )
                                .animation(IslandSprings.hudProgress, value: session.progress)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 12)
                }
            }

            // Bottom Row: Interactive Action Buttons
            actionButtonsRow
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var previewThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.28),
                            Color.blue.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 52)

            if isCodeSession {
                Image(systemName: "key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.cyan)
            } else if let img = session.previewImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: isLinkSession ? "safari.fill" : "doc.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.cyan)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
        )
    }

    private var isLinkSession: Bool {
        if case .webLink = session.payloadKind { return true }
        return false
    }

    private var isCodeSession: Bool {
        if case .verificationCode = session.payloadKind { return true }
        return session.phase == .awaitingVerificationCode
    }

    private var formattedVerificationCode: String {
        let digits = session.itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count == 6 else { return digits }
        let mid = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<mid]) \(digits[mid...])"
    }

    @ViewBuilder
    private var actionButtonsRow: some View {
        switch session.phase {
        case .awaitingConfirmation:
            HStack(spacing: 10) {
                AirDropCardActionButton(
                    title: "Decline",
                    symbolName: "xmark",
                    fillColor: Color.white.opacity(0.12),
                    textColor: .white.opacity(0.9)
                ) {
                    plugin.declineTransfer()
                }

                AirDropCardActionButton(
                    title: isLinkSession ? "Accept & Open" : "Accept",
                    symbolName: "checkmark",
                    fillColor: Color.cyan,
                    textColor: .black
                ) {
                    plugin.acceptTransfer()
                }
            }

        case .awaitingVerificationCode:
            HStack(spacing: 10) {
                AirDropCardActionButton(
                    title: "Dismiss",
                    symbolName: "xmark",
                    fillColor: Color.white.opacity(0.12),
                    textColor: .white.opacity(0.9)
                ) {
                    plugin.declineTransfer()
                }

                AirDropCardActionButton(
                    title: "Copy Code",
                    symbolName: "doc.on.doc.fill",
                    fillColor: Color.cyan,
                    textColor: .black
                ) {
                    plugin.copyVerificationCode()
                }
            }

        case .transferring:
            HStack(spacing: 10) {
                if session.isIndeterminateProgress {
                    HStack(spacing: 6) {
                        AirDropIndeterminateSpinnerView(size: 12, lineWidth: 1.8)
                        Text("Receiving file…")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                } else {
                    Text("\(Int((session.progress * 100).rounded()))% completed")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                }

                Spacer()

                AirDropCardActionButton(
                    title: "Cancel",
                    symbolName: "xmark",
                    fillColor: Color.white.opacity(0.12),
                    textColor: .white.opacity(0.9),
                    compactWidth: true
                ) {
                    plugin.declineTransfer()
                }
            }

        case .completed:
            HStack(spacing: 10) {
                AirDropCardActionButton(
                    title: "Dismiss",
                    symbolName: "xmark",
                    fillColor: Color.white.opacity(0.10),
                    textColor: .white.opacity(0.85)
                ) {
                    plugin.dismissCompletedSession()
                }

                if isLinkSession {
                    AirDropCardActionButton(
                        title: "Open Link",
                        symbolName: "safari.fill",
                        fillColor: Color.cyan,
                        textColor: .black
                    ) {
                        plugin.openReceivedItems()
                    }
                } else {
                    AirDropCardActionButton(
                        title: "Finder",
                        symbolName: "folder.fill",
                        fillColor: Color.white.opacity(0.16),
                        textColor: .white
                    ) {
                        plugin.revealReceivedItemsInFinder()
                    }

                    AirDropCardActionButton(
                        title: "Open",
                        symbolName: "arrow.up.right.square.fill",
                        fillColor: Color.cyan,
                        textColor: .black
                    ) {
                        plugin.openReceivedItems()
                    }
                }
            }

        case .declined, .failed:
            EmptyView()
        }
    }
}

private struct AirDropIndeterminateSpinnerView: View {
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t * 320.0).truncatingRemainder(dividingBy: 360.0))
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.20), lineWidth: lineWidth)
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0.0, to: 0.34)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(angle)
                    .frame(width: size, height: size)
            }
        }
    }
}

private struct AirDropIndeterminateProgressBarView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((sin(t * 2.6) + 1.0) * 0.5) // 0.0 ... 1.0 smooth oscillation
            GeometryReader { geo in
                let barWidth = max(44, geo.size.width * 0.36)
                let travel = max(0, geo.size.width - barWidth)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 6)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan, Color(red: 0.25, green: 0.88, blue: 0.72)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: barWidth, height: 6)
                        .offset(x: travel * phase)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

private struct AirDropCardActionButton: View {
    let title: String
    let symbolName: String
    let fillColor: Color
    let textColor: Color
    var compactWidth: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(textColor)
            .padding(.horizontal, compactWidth ? 14 : 12)
            .padding(.vertical, 8.5)
            .frame(maxWidth: compactWidth ? nil : .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor.opacity(isPressed ? 0.78 : (isHovered ? 0.92 : 1.0)))
            )
            .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.02 : 1.0))
            .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isHovered)
            .animation(.spring(response: 0.12, dampingFraction: 0.8), value: isPressed)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Outgoing AirDrop Views (Dropzone, Compact Shelf Wings, Recipient Picker)

public struct AirDropOutgoingCompactLeadingView: View {
    public let phase: AirDropOutgoingPhase

    public init(phase: AirDropOutgoingPhase) {
        self.phase = phase
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.18))
                .frame(width: 20, height: 20)

            Image(systemName: "arrow.up.doc.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.cyan)
                .symbolEffect(.pulse, isActive: isSending)
        }
    }

    private var isSending: Bool {
        if case .sending = phase { return true }
        return false
    }
}

public struct AirDropOutgoingCompactTrailingView: View {
    public let session: AirDropOutgoingSession

    public init(session: AirDropOutgoingSession) {
        self.session = session
    }

    public var body: some View {
        switch session.phase {
        case .dropzoneHover, .selectingRecipient:
            HStack(spacing: 4) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.cyan)
                Text(session.compactWingBadgeText)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

        case .sending:
            HStack(spacing: 5) {
                AirDropIndeterminateSpinnerView(size: 12, lineWidth: 2.0)
                Text("Sending")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.green)
                Text("Sent")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

public struct AirDropOutgoingExpandedCardView: View {
    @ObservedObject public var plugin: AirDropPlugin
    public let session: AirDropOutgoingSession

    public init(plugin: AirDropPlugin, session: AirDropOutgoingSession) {
        self.plugin = plugin
        self.session = session
    }

    public var body: some View {
        switch session.phase {
        case .dropzoneHover:
            dropzoneHoverView
        case .selectingRecipient, .sending, .completed:
            recipientPickerView
        }
    }

    private var dropzoneHoverView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cyan.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            Color.cyan.opacity(0.65),
                            style: StrokeStyle(lineWidth: 1.6, dash: [6, 5])
                        )
                )

            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.cyan)
                        .symbolEffect(.pulse)
                }

                Text("Drop Files to AirDrop")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)

                Text("Release to stage files and pick a nearby receiver")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var recipientPickerView: some View {
        VStack(spacing: 10) {
            // Top Row: Staged File Summary + Quick Cancel Button
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.28), Color.blue.opacity(0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)

                    if let img = session.previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: session.fileURLs.count > 1 ? "doc.on.doc.fill" : "doc.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.cyan)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "airplayaudio")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.cyan)
                        Text(session.itemTitle)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }

                    Text(session.itemSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    plugin.cancelOutgoingSession()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Cancel AirDrop")
            }

            // Middle Row: Discovered Receivers or Transfer Status
            middleRecipientRow

            // Bottom Row: Cancel / Done Action
            AirDropCardActionButton(
                title: isCompleted ? "Done" : "Cancel",
                symbolName: isCompleted ? "checkmark" : "xmark",
                fillColor: Color.white.opacity(0.12),
                textColor: .white.opacity(0.9)
            ) {
                plugin.cancelOutgoingSession()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private var isCompleted: Bool {
        if case .completed = session.phase { return true }
        return false
    }

    @ViewBuilder
    private var middleRecipientRow: some View {
        switch session.phase {
        case .dropzoneHover:
            EmptyView()

        case .selectingRecipient:
            if session.recipients.isEmpty {
                HStack(spacing: 8) {
                    AirDropIndeterminateSpinnerView(size: 13, lineWidth: 2.0)
                    Text("Searching nearby AirDrop devices…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.recipients) { recipient in
                            AirDropRecipientChipButton(recipient: recipient) {
                                plugin.sendOutgoingToRecipient(recipient)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 52)
            }

        case .sending(let recipientName):
            VStack(spacing: 6) {
                AirDropIndeterminateProgressBarView()
                    .frame(height: 10)
                Text("Waiting for \(recipientName) to accept…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
            }
            .frame(height: 50)

        case .completed(let recipientName):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.green)
                Text("Sent to \(recipientName)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.green)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            )
        }
    }
}

private struct AirDropRecipientChipButton: View {
    let recipient: AirDropDiscoveredRecipient
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.22))
                        .frame(width: 32, height: 32)

                    if let icon = recipient.avatarIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: recipient.deviceSymbolName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.cyan)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(recipient.displayName)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(recipient.secondaryName ?? recipient.deviceModel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isHovered ? Color.cyan.opacity(0.22) : Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isHovered ? Color.cyan.opacity(0.65) : Color.white.opacity(0.12), lineWidth: 0.9)
            )
            .scaleEffect(isPressed ? 0.95 : (isHovered ? 1.02 : 1.0))
            .animation(.spring(response: 0.16, dampingFraction: 0.76), value: isHovered)
            .animation(.spring(response: 0.12, dampingFraction: 0.8), value: isPressed)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - AirDropPlugin (`NotchPlugin`)

@MainActor
public final class AirDropPlugin: ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.airdrop"
    public let displayName = "AirDrop Receiver"
    public let symbolName = "airplayaudio"

    @Published public var isEnabled: Bool = true
    @Published public var autoExpandIncomingAlerts: Bool {
        didSet {
            UserDefaults.standard.set(autoExpandIncomingAlerts, forKey: "island.airdrop.autoExpandIncomingAlerts")
            if let current = receiverService.activeSession {
                syncSessionWithCoordinator(current)
            }
        }
    }
    @Published public var autoOpenLinks: Bool {
        didSet {
            UserDefaults.standard.set(autoOpenLinks, forKey: "island.airdrop.autoOpenLinks")
        }
    }
    @Published public var replaceSystemNotification: Bool {
        didSet {
            UserDefaults.standard.set(replaceSystemNotification, forKey: "island.airdrop.replaceSystemNotification")
            if isEnabled {
                receiverService.start(replaceSystemNotification: replaceSystemNotification)
            }
        }
    }
    @Published public var hudDuration: Double {
        didSet {
            UserDefaults.standard.set(hudDuration, forKey: "island.airdrop.hudDuration")
        }
    }

    public let receiverService = AirDropReceiverService()
    public let senderService = AirDropSenderService()
    private weak var coordinator: NotchStateCoordinator?
    private var autoDismissTask: Task<Void, Never>?
    private var awaitingConfirmationMinimizeTask: Task<Void, Never>?
    private var minimizedAwaitingSessionIDs = Set<String>()
    private var autoOpenedSessionIDs = Set<String>()
    private var openedOutgoingSessionIDs = Set<String>()
    private var hoverCancellable: AnyCancellable?

    public init() {
        let savedEnabled = UserDefaults.standard.object(forKey: "island.plugin.com.island.plugin.airdrop.enabled") as? Bool ?? true
        self.isEnabled = savedEnabled
        self.autoExpandIncomingAlerts = UserDefaults.standard.object(forKey: "island.airdrop.autoExpandIncomingAlerts") as? Bool ?? true
        self.autoOpenLinks = UserDefaults.standard.object(forKey: "island.airdrop.autoOpenLinks") as? Bool ?? true
        self.replaceSystemNotification = UserDefaults.standard.object(forKey: "island.airdrop.replaceSystemNotification") as? Bool ?? true
        self.hudDuration = UserDefaults.standard.object(forKey: "island.airdrop.hudDuration") as? Double ?? 4.0

        receiverService.onSessionUpdated = { [weak self] session in
            self?.syncSessionWithCoordinator(session)
        }
        senderService.onSessionUpdated = { [weak self] session in
            self?.syncOutgoingSessionWithCoordinator(session)
        }
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        hoverCancellable?.cancel()
        hoverCancellable = coordinator.$isHovering
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering in
                guard let self else { return }
                let hasCompletedSession = (self.receiverService.activeSession?.phase == .completed)
                    || (self.senderService.activeSession?.phase.isCompleted == true)
                if !hovering, hasCompletedSession {
                    // As soon as the user moves their cursor out of the expanded completed card,
                    // start a brief 1.5s timer to dismiss the completed AirDrop session.
                    self.scheduleCompletedAutoDismiss(delaySeconds: 1.5)
                } else if hovering, hasCompletedSession {
                    // Cancel auto-dismiss while the user is actively hovering/inspecting the completed AirDrop card!
                    self.autoDismissTask?.cancel()
                }
            }
        receiverService.start(replaceSystemNotification: replaceSystemNotification)
    }

    public func stop() {
        autoDismissTask?.cancel()
        awaitingConfirmationMinimizeTask?.cancel()
        hoverCancellable?.cancel()
        receiverService.stop()
        senderService.cancelOutgoingSession()
        coordinator?.clearPersistentActivity(pluginID: id)
    }

    // MARK: - Interactive Actions

    public func acceptTransfer() {
        receiverService.acceptCurrentTransfer()
    }

    public func declineTransfer() {
        autoDismissTask?.cancel()
        receiverService.declineCurrentTransfer()
        coordinator?.clearPersistentActivity(pluginID: id, forceCollapseHover: true)
    }

    public func dismissCompletedSession() {
        autoDismissTask?.cancel()
        awaitingConfirmationMinimizeTask?.cancel()
        receiverService.clearActiveSession()
        coordinator?.clearPersistentActivity(pluginID: id, forceCollapseHover: true)
    }

    public func openReceivedItems() {
        guard let session = receiverService.activeSession else { return }
        switch session.payloadKind {
        case .webLink(let url):
            if let target = url ?? session.completedURLs.first {
                NSWorkspace.shared.open(target)
            } else {
                _ = receiverService.triggerCompletionBannerAction(preferFinder: false)
            }
        case .files:
            let existingURLs = session.completedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existingURLs.isEmpty {
                for url in existingURLs {
                    NSWorkspace.shared.open(url)
                }
            } else if !receiverService.triggerCompletionBannerAction(preferFinder: false),
                      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(downloads)
            }
        case .verificationCode(let code):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            return
        }
        dismissCompletedSession()
    }

    public func copyVerificationCode() {
        guard let session = receiverService.activeSession else { return }
        let code: String = {
            if case .verificationCode(let c) = session.payloadKind { return c }
            return session.itemTitle
        }()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    public func revealReceivedItemsInFinder() {
        guard let session = receiverService.activeSession else { return }
        let existingURLs = session.completedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existingURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
        } else if !receiverService.triggerCompletionBannerAction(preferFinder: true),
                  let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(downloads)
        }
        dismissCompletedSession()
    }

    public func simulateIncomingFileRequest() {
        receiverService.simulateIncomingFileTransfer()
    }

    public func simulateIncomingLinkRequest() {
        receiverService.simulateIncomingLinkShare()
    }

    public func simulateIncomingCodeRequest() {
        receiverService.simulateIncomingVerificationCode()
    }

    // MARK: - Outgoing AirDrop Actions (Drag-to-Send)

    public func handleFileDragHoverChanged(_ isHovering: Bool) {
        guard isEnabled else { return }
        senderService.setDropzoneHoverActive(isHovering)
    }

    public func handleDroppedFiles(_ urls: [URL]) {
        guard isEnabled else { return }
        senderService.stageDroppedFiles(urls)
    }

    public func sendOutgoingToRecipient(_ recipient: AirDropDiscoveredRecipient) {
        senderService.sendToRecipient(recipient)
    }

    public func cancelOutgoingSession() {
        autoDismissTask?.cancel()
        if let id = senderService.activeSession?.id {
            openedOutgoingSessionIDs.remove(id)
        }
        senderService.cancelOutgoingSession()
        if let incoming = receiverService.activeSession {
            syncSessionWithCoordinator(incoming)
        } else {
            coordinator?.clearPersistentActivity(pluginID: id, forceCollapseHover: true)
        }
    }

    public func simulateOutgoingDrop() {
        senderService.simulateOutgoingFileDrop()
    }

    // MARK: - Coordinator Synchronization

    public func syncSessionWithCoordinator(_ session: AirDropTransferSession?) {
        guard isEnabled, let coordinator else { return }
        autoDismissTask?.cancel()
        awaitingConfirmationMinimizeTask?.cancel()

        guard let session else {
            if let outgoing = senderService.activeSession {
                syncOutgoingSessionWithCoordinator(outgoing)
            } else {
                coordinator.clearPersistentActivity(pluginID: id, forceCollapseHover: true)
            }
            return
        }

        // Automatically open web links on completion if configured
        if session.phase == .completed,
           case .webLink(let linkURL) = session.payloadKind,
           autoOpenLinks,
           !autoOpenedSessionIDs.contains(session.id) {
            autoOpenedSessionIDs.insert(session.id)
            if let url = linkURL ?? session.completedURLs.first {
                NSWorkspace.shared.open(url)
            }
        }

        let leading = AnyView(AirDropCompactLeadingView(phase: session.phase))
        let trailing = AnyView(AirDropCompactTrailingView(session: session))
        let expanded = AnyView(AirDropExpandedCardView(plugin: self, session: session))

        // Posture logic:
        // - `.awaitingConfirmation` / `.awaitingVerificationCode`: When `autoExpandIncomingAlerts` is enabled,
        //   expand immediately into the interactive card, then minimize to `.compactWings` after 10 seconds.
        //   When `autoExpandIncomingAlerts` is disabled, start in `.compactWings` and expand on hover/click.
        // - `.transferring` / `.completed`: Collapse to compact wings (while still allowing hover to open the full card)
        let isAwaitingPrompt = (session.phase == .awaitingConfirmation || session.phase == .awaitingVerificationCode)
        let isMinimizedAfterTimeout = minimizedAwaitingSessionIDs.contains(session.id)
        let targetPosture: NotchPosture = (isAwaitingPrompt && autoExpandIncomingAlerts && !isMinimizedAfterTimeout)
            ? .expandedCard
            : .compactWings

        let rightWingWidth: CGFloat = {
            switch session.phase {
            case .awaitingConfirmation: return 62
            case .awaitingVerificationCode: return 78
            case .transferring: return 68
            case .completed: return 68
            case .declined, .failed: return 36
            }
        }()

        let payload = NotchActivityPayload(
            id: session.id,
            pluginID: id,
            priority: .critical,
            posture: targetPosture,
            wingSizes: NotchWingSizes(leftWidth: 36, rightWidth: rightWingWidth),
            compactLeadingView: leading,
            compactTrailingView: trailing,
            expandedView: expanded,
            accentColor: .cyan
        )

        coordinator.publishPersistentActivity(payload)

        // If waiting for Accept/Decline or 6-digit code entry and auto-expanded, start a 10-second inactivity timer
        // to retract the expanded card into compact wings if the user doesn't react.
        if isAwaitingPrompt && autoExpandIncomingAlerts && !isMinimizedAfterTimeout {
            let sessionID = session.id
            awaitingConfirmationMinimizeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self,
                      let current = self.receiverService.activeSession,
                      current.id == sessionID,
                      (current.phase == .awaitingConfirmation || current.phase == .awaitingVerificationCode) else { return }
                self.minimizedAwaitingSessionIDs.insert(sessionID)
                self.syncSessionWithCoordinator(current)
            }
        }

        if session.phase == .completed {
            scheduleCompletedAutoDismiss(delaySeconds: max(2.5, hudDuration))
        }
    }

    public func syncOutgoingSessionWithCoordinator(_ session: AirDropOutgoingSession?) {
        guard isEnabled, let coordinator else { return }
        autoDismissTask?.cancel()

        guard let session else {
            if let incoming = receiverService.activeSession {
                syncSessionWithCoordinator(incoming)
            } else {
                coordinator.clearPersistentActivity(pluginID: id, forceCollapseHover: true)
            }
            return
        }

        let leading = AnyView(AirDropOutgoingCompactLeadingView(phase: session.phase))
        let trailing = AnyView(AirDropOutgoingCompactTrailingView(session: session))
        let expanded = AnyView(AirDropOutgoingExpandedCardView(plugin: self, session: session))

        // `.dropzoneHover` forces `.expandedCard` while dragging files near the notch.
        // `.selectingRecipient` uses `.compactWings` as its resting activity posture and activates
        // hover expansion (`handleNotchClicked()`) on initial drop so that moving the cursor away
        // smoothly collapses into compact wings ("1 File" / "N Files") and moving back re-expands!
        let targetPosture: NotchPosture = (session.phase == .dropzoneHover) ? .expandedCard : .compactWings

        let rightWingWidth: CGFloat = {
            switch session.phase {
            case .dropzoneHover, .selectingRecipient, .sending, .completed:
                return 68
            }
        }()

        let payload = NotchActivityPayload(
            id: session.id,
            pluginID: id,
            priority: .critical,
            posture: targetPosture,
            wingSizes: NotchWingSizes(leftWidth: 36, rightWidth: rightWingWidth),
            compactLeadingView: leading,
            compactTrailingView: trailing,
            expandedView: expanded,
            accentColor: .cyan
        )

        coordinator.publishPersistentActivity(payload)

        if session.phase == .selectingRecipient && !openedOutgoingSessionIDs.contains(session.id) {
            openedOutgoingSessionIDs.insert(session.id)
            coordinator.handleNotchClicked()
        }

        if session.phase.isCompleted {
            scheduleCompletedAutoDismiss(delaySeconds: max(2.5, hudDuration))
        }
    }

    private func scheduleCompletedAutoDismiss(delaySeconds: Double) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, let coordinator = self.coordinator else { return }
            // Never swap back to Music or dismiss while the user is actively hovering inside the expanded card!
            if coordinator.isHovering || coordinator.posture == .expandedCard {
                return
            }
            if self.senderService.activeSession?.phase.isCompleted == true {
                if let id = self.senderService.activeSession?.id {
                    self.openedOutgoingSessionIDs.remove(id)
                }
                self.senderService.cancelOutgoingSession()
            }
            if self.receiverService.activeSession?.phase == .completed {
                self.receiverService.clearActiveSession()
            }
            if self.receiverService.activeSession == nil && self.senderService.activeSession == nil {
                coordinator.clearPersistentActivity(pluginID: self.id)
            }
        }
    }
}
