import Combine
import Foundation
import IOKit.ps
import SwiftUI

public enum PowerEventKind: Equatable, Sendable {
    case charging(percentage: Int)
    case lowBattery(percentage: Int)
    case lowPowerMode(enabled: Bool, percentage: Int)
}

public struct PowerStatusBannerView: View {
    public let event: PowerEventKind
    @Environment(\.notchDeadZoneWidth) private var notchDeadZoneWidth
    @Environment(\.notchWingSizes) private var wingSizes

    public init(event: PowerEventKind) {
        self.event = event
    }

    public var body: some View {
        NotchSplitWingContainer(
            leftWingWidth: wingSizes.leftWidth,
            physicalNotchWidth: notchDeadZoneWidth,
            rightWingWidth: wingSizes.rightWidth
        ) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accentColor)
                    .contentTransition(.symbolEffect(.replace))

                Text(titleText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } trailing: {
            Text(badgeText)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(accentColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleText: String {
        switch event {
        case .charging:
            return "Charging"
        case .lowBattery:
            return "Low Battery"
        case .lowPowerMode(let enabled, _):
            return enabled ? "Energy Saver" : "Saver Off"
        }
    }

    private var badgeText: String {
        switch event {
        case .charging(let pct), .lowBattery(let pct), .lowPowerMode(_, let pct):
            return "\(pct)%"
        }
    }

    private var symbolName: String {
        switch event {
        case .charging:
            return "bolt.batteryblock.fill"
        case .lowBattery(let pct):
            return pct <= 10 ? "battery.0percent" : "battery.25percent"
        case .lowPowerMode:
            return "battery.50percent"
        }
    }

    private var accentColor: Color {
        switch event {
        case .charging:
            return .green
        case .lowBattery(let pct):
            return pct <= 10 ? .red : .orange
        case .lowPowerMode(let enabled, _):
            return enabled ? .yellow : .white
        }
    }
}

@MainActor
public final class BatteryPowerPlugin: ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.battery"
    public let displayName = "Battery & Low Power Alerts"
    public let symbolName = "bolt.batteryblock.fill"
    @Published public var isEnabled: Bool = true
    @Published public var hudDuration: Double {
        didSet {
            UserDefaults.standard.set(hudDuration, forKey: "island.battery.hudDuration")
        }
    }
    @Published public var lowBatteryThreshold: Double {
        didSet {
            UserDefaults.standard.set(lowBatteryThreshold, forKey: "island.battery.lowBatteryThreshold")
        }
    }
    @Published public var notifyOnChargerConnected: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnChargerConnected, forKey: "island.battery.notifyCharger")
        }
    }
    @Published public var notifyOnLowPowerMode: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnLowPowerMode, forKey: "island.battery.notifyLowPowerMode")
        }
    }

    private weak var coordinator: NotchStateCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var powerRunLoopSource: CFRunLoopSource?
    private var lastChargingState: Bool?
    private var lastLowBatteryThresholdWarned: Int?

    public init() {
        let saved = UserDefaults.standard.object(forKey: "island.plugin.\(id).enabled") as? Bool ?? true
        self.isEnabled = saved
        self.hudDuration = UserDefaults.standard.object(forKey: "island.battery.hudDuration") as? Double ?? 2.5
        self.lowBatteryThreshold = UserDefaults.standard.object(forKey: "island.battery.lowBatteryThreshold") as? Double ?? 20.0
        self.notifyOnChargerConnected = UserDefaults.standard.object(forKey: "island.battery.notifyCharger") as? Bool ?? true
        self.notifyOnLowPowerMode = UserDefaults.standard.object(forKey: "island.battery.notifyLowPowerMode") as? Bool ?? true
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        cancellables.removeAll()

        let initial = readBatterySnapshot()
        lastChargingState = initial.isCharging

        // Observe Low Power Mode changes
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.notifyOnLowPowerMode else { return }
                let snap = self.readBatterySnapshot()
                let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.presentPowerEvent(.lowPowerMode(enabled: isLowPower, percentage: snap.percentage))
            }
            .store(in: &cancellables)

        // Observe IOKit power source changes (plugging/unplugging charger, battery drop)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let plugin = Unmanaged<BatteryPowerPlugin>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                plugin.evaluatePowerSourceChange()
            }
        }, selfPtr)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerRunLoopSource = source
        }
    }

    public func stop() {
        cancellables.removeAll()
        if let source = powerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerRunLoopSource = nil
        }
    }

    public func readBatterySnapshot() -> (percentage: Int, isCharging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (100, false)
        }

        for ps in list {
            if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] {
                let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
                let powerSourceState = desc[kIOPSPowerSourceStateKey as String] as? String
                let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool ?? false) || (powerSourceState == kIOPSACPowerValue as String)
                return (capacity, isCharging)
            }
        }
        return (100, false)
    }

    private func evaluatePowerSourceChange() {
        let snap = readBatterySnapshot()

        if let prevCharging = lastChargingState, prevCharging != snap.isCharging {
            lastChargingState = snap.isCharging
            if snap.isCharging && notifyOnChargerConnected {
                presentPowerEvent(.charging(percentage: snap.percentage))
                lastLowBatteryThresholdWarned = nil
                return
            }
        } else {
            lastChargingState = snap.isCharging
        }

        let thresholdInt = Int(lowBatteryThreshold.rounded())
        if !snap.isCharging {
            if snap.percentage <= 10 && lastLowBatteryThresholdWarned != 10 {
                lastLowBatteryThresholdWarned = 10
                presentPowerEvent(.lowBattery(percentage: snap.percentage))
            } else if snap.percentage <= thresholdInt && lastLowBatteryThresholdWarned == nil {
                lastLowBatteryThresholdWarned = thresholdInt
                presentPowerEvent(.lowBattery(percentage: snap.percentage))
            }
        }
    }

    public func presentPowerEvent(_ event: PowerEventKind) {
        guard isEnabled, let coordinator else { return }
        let view = PowerStatusBannerView(event: event)
        let priority: NotchPriority = {
            if case .lowBattery(let pct) = event, pct <= 10 {
                return .critical
            }
            return .high
        }()
        // Asymmetric content-fitted wings: left wing fits the icon + label ("Low Battery"),
        // right wing fits just the compact percentage ("15%")
        let wingSizes: NotchWingSizes = {
            switch event {
            case .charging:
                return NotchWingSizes(leftWidth: 92, rightWidth: 48)
            case .lowBattery:
                return NotchWingSizes(leftWidth: 108, rightWidth: 46)
            case .lowPowerMode(let enabled, _):
                return NotchWingSizes(leftWidth: enabled ? 114 : 94, rightWidth: 46)
            }
        }()
        let payload = NotchActivityPayload(
            pluginID: id,
            priority: priority,
            posture: .transientHUD,
            duration: hudDuration,
            wingSizes: wingSizes,
            hudView: AnyView(view)
        )
        coordinator.presentTransientHUD(payload)
        IslandLogger.system.info("Presented power HUD event")
    }
}
