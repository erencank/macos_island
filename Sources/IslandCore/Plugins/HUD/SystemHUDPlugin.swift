import Combine
import Foundation
import SwiftUI

public enum SystemHUDKind: Equatable, Sendable {
    case sound(level: Float, isMuted: Bool)
    case display(level: Float)
}

/// Renders the exact Alcove-inspired horizontal Sound & Display HUD inside the notch
/// (Icon + label on the left wing, smooth white capsule progress bar on the right wing)
public struct SystemHUDNotchBannerView: View {
    public let kind: SystemHUDKind
    public let coloredFill: Bool
    @Environment(\.notchDeadZoneWidth) private var notchDeadZoneWidth
    @Environment(\.notchWingSizes) private var wingSizes

    public init(kind: SystemHUDKind, coloredFill: Bool = false) {
        self.kind = kind
        self.coloredFill = coloredFill
    }

    public var body: some View {
        NotchSplitWingContainer(
            leftWingWidth: wingSizes.leftWidth,
            physicalNotchWidth: notchDeadZoneWidth,
            rightWingWidth: wingSizes.rightWidth
        ) {
            // Left Wing: Dynamic SF Symbol + Label ("Sound" or "Display")
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(coloredFill ? accentColor : .white)
                    .frame(width: 16, alignment: .center)
                    .contentTransition(.symbolEffect(.replace))

                Text(titleText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } trailing: {
            // Right Wing: Snug horizontal progress track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.24))
                        .frame(height: 5.5)

                    Capsule(style: .continuous)
                        .fill(coloredFill ? accentColor : Color.white)
                        .frame(
                            width: max(0, min(geo.size.width, geo.size.width * CGFloat(progressValue))),
                            height: 5.5
                        )
                        .animation(IslandSprings.hudProgress, value: progressValue)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 62, height: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accentColor: Color {
        switch kind {
        case .sound:
            return Color(red: 0.24, green: 0.89, blue: 0.71)
        case .display:
            return Color(red: 0.98, green: 0.78, blue: 0.28)
        }
    }

    private var titleText: String {
        switch kind {
        case .sound(_, let isMuted):
            return isMuted ? "Muted" : "Sound"
        case .display:
            return "Display"
        }
    }

    private var symbolName: String {
        switch kind {
        case .sound(let level, let isMuted):
            if isMuted || level <= 0.001 {
                return "speaker.slash.fill"
            } else if level < 0.33 {
                return "speaker.wave.1.fill"
            } else if level < 0.66 {
                return "speaker.wave.2.fill"
            } else {
                return "speaker.wave.3.fill"
            }
        case .display(let level):
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    private var progressValue: Float {
        switch kind {
        case .sound(let level, let isMuted):
            return isMuted ? 0.0 : max(0.0, min(1.0, level))
        case .display(let level):
            return max(0.0, min(1.0, level))
        }
    }
}

@MainActor
public final class SystemHUDPlugin: ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.systemhud"
    public let displayName = "Sound & Display HUD"
    public let symbolName = "speaker.wave.3.fill"

    @Published public var isEnabled: Bool = true
    @Published public var replaceSoundHUD: Bool {
        didSet {
            UserDefaults.standard.set(replaceSoundHUD, forKey: "island.hud.replaceSound")
            eventTapService.interceptSoundKeys = replaceSoundHUD
            updateTapRegistration()
        }
    }
    @Published public var replaceDisplayHUD: Bool {
        didSet {
            UserDefaults.standard.set(replaceDisplayHUD, forKey: "island.hud.replaceDisplay")
            eventTapService.interceptBrightnessKeys = replaceDisplayHUD
            updateTapRegistration()
        }
    }
    @Published public var hudDuration: Double {
        didSet {
            UserDefaults.standard.set(hudDuration, forKey: "island.hud.duration")
        }
    }
    @Published public var useColoredProgressBar: Bool {
        didSet {
            UserDefaults.standard.set(useColoredProgressBar, forKey: "island.hud.coloredBar")
        }
    }

    private weak var coordinator: NotchStateCoordinator?
    private let eventTapService = HIDEventTapService()
    private let audioService = AudioControlService()
    private let brightnessService = BrightnessControlService()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        let savedSound = UserDefaults.standard.object(forKey: "island.hud.replaceSound") as? Bool ?? true
        let savedDisplay = UserDefaults.standard.object(forKey: "island.hud.replaceDisplay") as? Bool ?? true
        self.replaceSoundHUD = savedSound
        self.replaceDisplayHUD = savedDisplay
        self.hudDuration = UserDefaults.standard.object(forKey: "island.hud.duration") as? Double ?? 1.65
        self.useColoredProgressBar = UserDefaults.standard.object(forKey: "island.hud.coloredBar") as? Bool ?? false

        eventTapService.interceptSoundKeys = savedSound
        eventTapService.interceptBrightnessKeys = savedDisplay

        eventTapService.onHardwareKeyTriggered = { [weak self] key in
            Task { @MainActor [weak self] in
                self?.handleHardwareKey(key)
            }
        }
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator

        AccessibilityManager.shared.$isTrusted
            .receive(on: RunLoop.main)
            .sink { [weak self] trusted in
                guard let self else { return }
                if trusted {
                    self.updateTapRegistration()
                } else {
                    self.eventTapService.stop()
                }
            }
            .store(in: &cancellables)

        updateTapRegistration()
    }

    public func stop() {
        eventTapService.stop()
        cancellables.removeAll()
    }

    private func updateTapRegistration() {
        guard isEnabled && (replaceSoundHUD || replaceDisplayHUD) else {
            eventTapService.stop()
            return
        }
        if AccessibilityManager.shared.isTrusted {
            _ = eventTapService.start()
        }
    }

    private func handleHardwareKey(_ key: InterceptedHardwareKey) {
        let standardStep: Float = 1.0 / 16.0
        let fineStep: Float = 1.0 / 64.0

        switch key {
        case .volumeUp(let isFine):
            let delta = isFine ? fineStep : standardStep
            let result = audioService.stepVolume(delta: delta)
            presentHUD(kind: .sound(level: result.volume, isMuted: result.isMuted))

        case .volumeDown(let isFine):
            let delta = -(isFine ? fineStep : standardStep)
            let result = audioService.stepVolume(delta: delta)
            presentHUD(kind: .sound(level: result.volume, isMuted: result.isMuted))

        case .mute:
            let result = audioService.toggleMute()
            presentHUD(kind: .sound(level: result.volume, isMuted: result.isMuted))

        case .brightnessUp(let isFine):
            let delta = isFine ? fineStep : standardStep
            let level = brightnessService.stepBrightness(delta: delta)
            presentHUD(kind: .display(level: level))

        case .brightnessDown(let isFine):
            let delta = -(isFine ? fineStep : standardStep)
            let level = brightnessService.stepBrightness(delta: delta)
            presentHUD(kind: .display(level: level))
        }
    }

    public func presentHUD(kind: SystemHUDKind) {
        guard let coordinator else { return }
        let view = SystemHUDNotchBannerView(kind: kind, coloredFill: useColoredProgressBar)
        let leftWidth: CGFloat = {
            if case .display = kind { return 82 }
            return 78
        }()
        let payload = NotchActivityPayload(
            pluginID: id,
            priority: .high,
            posture: .transientHUD,
            duration: hudDuration,
            wingSizes: NotchWingSizes(leftWidth: leftWidth, rightWidth: 76),
            hudView: AnyView(view)
        )
        coordinator.presentTransientHUD(payload)
    }
}
