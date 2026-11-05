import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
public final class AccessibilityManager: ObservableObject {
    public static let shared = AccessibilityManager()

    @Published public private(set) var isTrusted: Bool = false
    @Published public var isShowingPermissionPopover: Bool = false

    private var pollTimer: Timer?

    private init() {
        refreshTrustStatus()
        startPollingTrustStatus()
    }

    public func refreshTrustStatus() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            IslandLogger.permissions.info("Accessibility trust status changed: \(trusted)")
            if trusted {
                isShowingPermissionPopover = false
            }
        }
    }

    /// Triggers the macOS Accessibility prompt and deep-links to System Settings > Privacy & Security > Accessibility
    public func requestAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue!] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        self.isTrusted = trusted

        if !trusted {
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(settingsURL)
            }
        }
    }

    private func startPollingTrustStatus() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTrustStatus()
            }
        }
    }
}

/// Matches the Alcove Accessibility permission popover from your screenshot:
/// Lock icon with blue accessibility badge + "Island needs your permission to replace the system HUDs." + "Ask Permission..." button
@MainActor
public struct HUDPermissionPopoverView: View {
    @ObservedObject public var accessibilityManager: AccessibilityManager
    public var onDismiss: () -> Void

    public init(
        accessibilityManager: AccessibilityManager,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.accessibilityManager = accessibilityManager
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 48)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.yellow.opacity(0.95), Color.orange],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.blue)
                        .frame(width: 22, height: 22)
                    Image(systemName: "figure.arms.open")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .offset(x: 6, y: 4)
            }
            .padding(.top, 4)

            Text("Island needs your permission\nto replace the system HUDs.")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                accessibilityManager.requestAccessibilityPermission()
                onDismiss()
            } label: {
                Text("Ask Permission...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.12, green: 0.11, blue: 0.15))
        )
    }
}
