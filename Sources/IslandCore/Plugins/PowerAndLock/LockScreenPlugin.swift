import Combine
import Foundation
import SwiftUI

public struct LockScreenBannerView: View {
    public let isLocked: Bool
    @State private var animatedLockState: Bool
    @Environment(\.notchDeadZoneWidth) private var notchDeadZoneWidth
    @Environment(\.notchWingSizes) private var wingSizes

    public init(isLocked: Bool) {
        self.isLocked = isLocked
        self._animatedLockState = State(initialValue: !isLocked)
    }

    public var body: some View {
        NotchSplitWingContainer(
            leftWingWidth: wingSizes.leftWidth,
            physicalNotchWidth: notchDeadZoneWidth,
            rightWingWidth: wingSizes.rightWidth
        ) {
            HStack(spacing: 6) {
                Image(systemName: animatedLockState ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(animatedLockState ? .orange : .green)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)

                Text(animatedLockState ? "Locked" : "Unlocked")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } trailing: {
            Circle()
                .fill(animatedLockState ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(IslandSprings.expand.delay(0.08)) {
                animatedLockState = isLocked
            }
        }
    }
}

@MainActor
public final class LockScreenPlugin: ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.lockscreen"
    public let displayName = "Lock Screen Padlock"
    public let symbolName = "lock.fill"
    @Published public var isEnabled: Bool = true
    @Published public var hudDuration: Double {
        didSet {
            UserDefaults.standard.set(hudDuration, forKey: "island.lock.hudDuration")
        }
    }
    @Published public var showOnUnlock: Bool {
        didSet {
            UserDefaults.standard.set(showOnUnlock, forKey: "island.lock.showOnUnlock")
        }
    }

    private weak var coordinator: NotchStateCoordinator?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        let saved = UserDefaults.standard.object(forKey: "island.plugin.\(id).enabled") as? Bool ?? true
        self.isEnabled = saved
        self.hudDuration = UserDefaults.standard.object(forKey: "island.lock.hudDuration") as? Double ?? 2.2
        self.showOnUnlock = UserDefaults.standard.object(forKey: "island.lock.showOnUnlock") as? Bool ?? true
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        cancellables.removeAll()

        let dnc = DistributedNotificationCenter.default()

        dnc.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.presentLockTransition(isLocked: true)
            }
            .store(in: &cancellables)

        dnc.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.showOnUnlock else { return }
                self.presentLockTransition(isLocked: false)
            }
            .store(in: &cancellables)
    }

    public func stop() {
        cancellables.removeAll()
    }

    public func presentLockTransition(isLocked: Bool) {
        guard isEnabled, let coordinator else { return }
        let view = LockScreenBannerView(isLocked: isLocked)
        let payload = NotchActivityPayload(
            pluginID: id,
            priority: .critical,
            posture: .transientHUD,
            duration: hudDuration,
            wingSizes: NotchWingSizes(leftWidth: isLocked ? 82 : 94, rightWidth: 28),
            hudView: AnyView(view),
            accentColor: isLocked ? .orange : .green
        )
        coordinator.presentTransientHUD(payload)
        IslandLogger.system.info("Presented lock screen state transition (locked: \(isLocked))")
    }
}
