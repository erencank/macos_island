import Combine
import Darwin
import Foundation
import IOBluetooth
import IOKit
import IOKit.ps
import SwiftUI

public enum BluetoothDeviceCategory: String, Equatable, Sendable {
    case airpodsPro
    case airpods
    case airpodsMax
    case beats
    case headphones
    case speaker
    case keyboard
    case mouse
    case trackpad
    case gameController
    case generic

    public var symbolName: String {
        switch self {
        case .airpodsPro:
            return "airpodspro"
        case .airpods:
            return "airpods"
        case .airpodsMax:
            return "airpodsmax"
        case .beats, .headphones:
            return "headphones"
        case .speaker:
            return "hifispeaker.fill"
        case .keyboard:
            return "keyboard.fill"
        case .mouse:
            return "magicmouse.fill"
        case .trackpad:
            return "trackpad.fill"
        case .gameController:
            return "gamecontroller.fill"
        case .generic:
            return "bolt.horizontal.circle.fill"
        }
    }

    public static func categorize(deviceName: String, minorClass: UInt32 = 0) -> BluetoothDeviceCategory {
        let lower = deviceName.lowercased()
        if lower.contains("airpods pro") {
            return .airpodsPro
        } else if lower.contains("airpods max") {
            return .airpodsMax
        } else if lower.contains("airpods") {
            return .airpods
        } else if lower.contains("beats") || lower.contains("solo") || lower.contains("studio") {
            return .beats
        } else if lower.contains("headphone") || lower.contains("wh-") || lower.contains("wf-") || lower.contains("xm3") || lower.contains("xm4") || lower.contains("xm5") || lower.contains("bose") || lower.contains("buds") || lower.contains("sennheiser") {
            return .headphones
        } else if lower.contains("speaker") || lower.contains("homepod") || lower.contains("flip") || lower.contains("boom") {
            return .speaker
        } else if lower.contains("keyboard") || lower.contains("keychron") || lower.contains("mx keys") {
            return .keyboard
        } else if lower.contains("trackpad") {
            return .trackpad
        } else if lower.contains("mouse") || lower.contains("mx master") {
            return .mouse
        } else if lower.contains("controller") || lower.contains("dualsense") || lower.contains("xbox") || lower.contains("joy-con") {
            return .gameController
        }
        return .generic
    }
}

public struct BluetoothStatusEvent: Equatable, Sendable {
    public let deviceName: String
    public let category: BluetoothDeviceCategory
    public let isConnected: Bool
    public let batteryPercentage: Int?

    public init(
        deviceName: String,
        category: BluetoothDeviceCategory,
        isConnected: Bool,
        batteryPercentage: Int?
    ) {
        self.deviceName = deviceName
        self.category = category
        self.isConnected = isConnected
        self.batteryPercentage = batteryPercentage
    }
}

/// Ultra-compact Bluetooth Notch HUD matching the compact wings style:
/// - Left wing: Device SF Symbol icon only (AirPods Pro, Headphones, Magic Mouse, Keyboard, etc.)
/// - Right wing: Combined Battery Percentage (e.g. `20%`) when connected, or `Off` when disconnected
public struct BluetoothStatusBannerView: View {
    public let event: BluetoothStatusEvent
    @Environment(\.notchDeadZoneWidth) private var notchDeadZoneWidth
    @Environment(\.notchWingSizes) private var wingSizes

    public init(event: BluetoothStatusEvent) {
        self.event = event
    }

    public var body: some View {
        NotchSplitWingContainer(
            leftWingWidth: wingSizes.leftWidth,
            physicalNotchWidth: notchDeadZoneWidth,
            rightWingWidth: wingSizes.rightWidth
        ) {
            // Left Wing: Device icon only
            Image(systemName: event.category.symbolName)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(event.isConnected ? .white : .white.opacity(0.45))
                .contentTransition(.symbolEffect(.replace))
                .help(event.deviceName)
        } trailing: {
            // Right Wing: Single combined battery percentage (or "Off" when disconnected)
            if event.isConnected {
                if let pct = event.batteryPercentage {
                    Text("\(pct)%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(batteryTintColor(for: pct))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green)
                }
            } else {
                Text("Off")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.48))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func batteryTintColor(for percentage: Int) -> Color {
        if percentage <= 15 {
            return .red
        } else if percentage <= 30 {
            return .orange
        }
        return .green
    }
}

@MainActor
public final class BluetoothStatusPlugin: NSObject, ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.bluetooth"
    public let displayName = "Bluetooth Device & Battery"
    public let symbolName = "airpodspro"
    @Published public var isEnabled: Bool = true
    @Published public var hudDuration: Double {
        didSet {
            UserDefaults.standard.set(hudDuration, forKey: "island.bt.hudDuration")
        }
    }
    @Published public var warnOnLowBattery: Bool {
        didSet {
            UserDefaults.standard.set(warnOnLowBattery, forKey: "island.bt.warnOnLowBattery")
        }
    }
    @Published public var lowBatteryThreshold: Double {
        didSet {
            UserDefaults.standard.set(lowBatteryThreshold, forKey: "island.bt.lowBatteryThreshold")
        }
    }
    @Published public var playSoundOnLowBattery: Bool {
        didSet {
            UserDefaults.standard.set(playSoundOnLowBattery, forKey: "island.bt.playSoundOnLowBattery")
        }
    }

    private weak var coordinator: NotchStateCoordinator?
    private var connectNotification: IOBluetoothUserNotification?
    private var deviceDisconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var knownConnectedAddresses = Set<String>()

    public override init() {
        let saved = UserDefaults.standard.object(forKey: "island.plugin.com.island.plugin.bluetooth.enabled") as? Bool ?? true
        self.isEnabled = saved
        self.hudDuration = UserDefaults.standard.object(forKey: "island.bt.hudDuration") as? Double ?? 2.5
        self.warnOnLowBattery = UserDefaults.standard.object(forKey: "island.bt.warnOnLowBattery") as? Bool ?? true
        self.lowBatteryThreshold = UserDefaults.standard.object(forKey: "island.bt.lowBatteryThreshold") as? Double ?? 20.0
        self.playSoundOnLowBattery = UserDefaults.standard.object(forKey: "island.bt.playSoundOnLowBattery") as? Bool ?? false
        super.init()
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        stop()

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired where device.isConnected() {
                if let addr = device.addressString {
                    knownConnectedAddresses.insert(addr)
                    registerDisconnectHook(for: device)
                }
            }
        }

        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(handleDeviceConnected(_:device:))
        )
    }

    public func triggerConnectedDevicePreview() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let connected = paired.first(where: { $0.isConnected() })
            ?? paired.first(where: {
                (Self.resolveBatteryPercentage(address: $0.addressString ?? "", deviceName: $0.nameOrAddress ?? "") ?? 0) > 0
            })

        if let target = connected {
            let name = target.nameOrAddress ?? "Bluetooth Device"
            let address = target.addressString ?? ""
            let category = BluetoothDeviceCategory.categorize(deviceName: name)
            let battery = Self.resolveBatteryPercentage(address: address, deviceName: name)
            print("[Island Bluetooth] Preview for '\(name)' (\(address)) -> battery: \(battery.map { "\($0)%" } ?? "nil")")
            presentBluetoothEvent(
                BluetoothStatusEvent(
                    deviceName: name,
                    category: category,
                    isConnected: true,
                    batteryPercentage: battery
                )
            )
        } else {
            // Even if no device returned isConnected() == true, check if any paired device has battery via bridge
            if let fallbackPct = Self.resolveBatteryPercentage(address: "", deviceName: "") {
                print("[Island Bluetooth] Preview fallback connected device -> battery: \(fallbackPct)%")
                presentBluetoothEvent(
                    BluetoothStatusEvent(
                        deviceName: "Bluetooth Headphones",
                        category: .headphones,
                        isConnected: true,
                        batteryPercentage: fallbackPct
                    )
                )
            } else {
                presentBluetoothEvent(
                    BluetoothStatusEvent(
                        deviceName: "AirPods Pro",
                        category: .airpodsPro,
                        isConnected: true,
                        batteryPercentage: 85
                    )
                )
            }
        }
    }

    public func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for (_, note) in deviceDisconnectNotifications {
            note.unregister()
        }
        deviceDisconnectNotifications.removeAll()
        knownConnectedAddresses.removeAll()
    }

    private func registerDisconnectHook(for device: IOBluetoothDevice) {
        guard let addr = device.addressString, deviceDisconnectNotifications[addr] == nil else { return }
        if let note = device.register(forDisconnectNotification: self, selector: #selector(handleDeviceDisconnected(_:device:))) {
            deviceDisconnectNotifications[addr] = note
        }
    }

    @objc private func handleDeviceConnected(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        guard let device else { return }
        let address = device.addressString ?? UUID().uuidString
        let name = device.nameOrAddress ?? "Bluetooth Device"

        registerDisconnectHook(for: device)

        guard !knownConnectedAddresses.contains(address) else { return }
        knownConnectedAddresses.insert(address)

        Task { @MainActor [weak self] in
            guard let self, self.isEnabled else { return }

            let currentName = device.nameOrAddress ?? name
            let category = BluetoothDeviceCategory.categorize(deviceName: currentName)

            // 1. Check immediately on connection (and poll every 50ms up to 200ms before presenting,
            // so if the battery arrives within the first 50ms-200ms we show the percentage right away without flashing the checkmark!)
            var initialBattery = Self.resolveBatteryPercentage(address: address, deviceName: currentName)
            if initialBattery == nil {
                for quickAttempt in 1...4 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if let pct = Self.resolveBatteryPercentage(address: address, deviceName: device.nameOrAddress ?? currentName) {
                        print("[Island Bluetooth] Battery arrived on quick poll #\(quickAttempt) (\(quickAttempt * 50)ms): \(pct)%")
                        initialBattery = pct
                        break
                    }
                }
            }

            print("[Island Bluetooth] Device connected: '\(currentName)' (\(address)), initialBattery: \(initialBattery.map { "\($0)%" } ?? "nil")")
            self.presentBluetoothEvent(
                BluetoothStatusEvent(
                    deviceName: currentName,
                    category: category,
                    isConnected: true,
                    batteryPercentage: initialBattery
                )
            )

            // 2. If battery still hasn't arrived after the initial 200ms window, continue polling every 50ms
            // and immediately replace the checkmark with the real percentage as soon as HFP reports it!
            if initialBattery == nil {
                for attempt in 1...60 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard self.isEnabled else { return }
                    if let pct = Self.resolveBatteryPercentage(address: address, deviceName: device.nameOrAddress ?? currentName) {
                        print("[Island Bluetooth] Battery arrived on attempt #\(attempt) (\(attempt * 50)ms): \(pct)%")
                        self.presentBluetoothEvent(
                            BluetoothStatusEvent(
                                deviceName: device.nameOrAddress ?? currentName,
                                category: category,
                                isConnected: true,
                                batteryPercentage: pct
                            )
                        )
                        break
                    }
                }
            }
        }
    }

    @objc private func handleDeviceDisconnected(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        guard let device else { return }
        let address = device.addressString ?? ""
        knownConnectedAddresses.remove(address)
        if let note = deviceDisconnectNotifications.removeValue(forKey: address) {
            note.unregister()
        }

        let name = device.nameOrAddress ?? "Bluetooth Device"
        let category = BluetoothDeviceCategory.categorize(deviceName: name)
        presentBluetoothEvent(
            BluetoothStatusEvent(
                deviceName: name,
                category: category,
                isConnected: false,
                batteryPercentage: nil
            )
        )
    }

    public func presentBluetoothEvent(_ event: BluetoothStatusEvent) {
        guard isEnabled, let coordinator else { return }
        let view = BluetoothStatusBannerView(event: event)
        let rightWidth: CGFloat = event.isConnected ? (event.batteryPercentage != nil ? 46 : 36) : 38
        let payload = NotchActivityPayload(
            pluginID: id,
            priority: .high,
            posture: .transientHUD,
            duration: hudDuration,
            wingSizes: NotchWingSizes(leftWidth: 36, rightWidth: rightWidth),
            hudView: AnyView(view),
            accentColor: event.isConnected ? .green : .gray
        )
        coordinator.presentTransientHUD(payload)
        IslandLogger.system.info("Presented Bluetooth HUD for \(event.deviceName, privacy: .public) (connected: \(event.isConnected), battery: \(event.batteryPercentage ?? -1))")
    }

    // MARK: - Multi-Source Bluetooth Battery Percentage Resolver

    public nonisolated static func resolveBatteryPercentage(address: String, deviceName: String) -> Int? {
        // 1. IMPORTANT: Query in a fresh short-lived subprocess FIRST!
        // `IOBluetooth.framework` caches `IOBluetoothDevice` instances per-process in a singleton table
        // and does NOT update `batteryPercentSingle` in-place when a device disconnects and reconnects
        // while the host app stays running. Spawning a fresh process forces IOBluetooth to fetch the
        // live XPC dictionary from `bluetoothd` every single time!
        if let freshPct = queryBatteryViaFreshSubprocess(query: address.isEmpty ? deviceName : address) {
            return freshPct
        }

        // 2. Fallback in-process native bridge check
        if let pct = queryBatteryViaNativeBridge(query: address.isEmpty ? deviceName : address) {
            return pct
        }

        // 2. Fallback KVC on a freshly fetched IOBluetoothDevice from `IOBluetoothDevice.pairedDevices()`
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            let lowerAddr = address.lowercased()
            let lowerName = deviceName.lowercased()
            for dev in paired {
                let dAddr = (dev.addressString ?? "").lowercased()
                let dName = (dev.nameOrAddress ?? "").lowercased()
                let isTargetMatch = (!lowerAddr.isEmpty && dAddr == lowerAddr) || (!lowerName.isEmpty && dName.contains(lowerName))
                let shouldInspect = isTargetMatch || (lowerAddr.isEmpty && lowerName.isEmpty && dev.isConnected())
                if shouldInspect {
                    var budPercentages: [Int] = []
                    for key in ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight"] {
                        if dev.responds(to: NSSelectorFromString(key)),
                           let num = dev.value(forKey: key) as? NSNumber {
                            let val = num.intValue
                            if val > 0 && val <= 100 {
                                budPercentages.append(val)
                            }
                        }
                    }
                    if !budPercentages.isEmpty {
                        return budPercentages.min()
                    }
                }
            }
        }

        // 3. Check IOPSCopyPowerSourcesInfo
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            let cleanTarget = deviceName.lowercased()
            for ps in list {
                if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
                   let psName = (desc[kIOPSNameKey as String] as? String)?.lowercased(),
                   let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int {
                    if psName.contains(cleanTarget) || cleanTarget.contains(psName) {
                        if capacity > 0 && capacity <= 100 {
                            return capacity
                        }
                    }
                }
            }
        }

        // 4. Check IORegistry `AppleDeviceManagementHIDEventService` (Magic Keyboard, Magic Mouse, Trackpad, etc.)
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            let cleanTarget = deviceName.lowercased()
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                let product = (IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String)?.lowercased() ?? ""
                if let pct = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
                   pct > 0 && pct <= 100 {
                    if product.isEmpty || product.contains(cleanTarget) || cleanTarget.contains(product) {
                        return pct
                    }
                }
            }
        }

        return nil
    }

    private nonisolated static func helperDylibPath() -> String? {
        let dylibCandidates: [String] = [
            Bundle.main.path(forResource: "libIslandMediaRemoteBridge", ofType: "dylib"),
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/libIslandMediaRemoteBridge.dylib").path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/libIslandMediaRemoteBridge.dylib").path
        ].compactMap { $0 }

        return dylibCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Spawns a fresh `/usr/bin/perl` one-liner that loads `libIslandMediaRemoteBridge.dylib` in a brand-new
    /// process space so `IOBluetooth` fetches an un-cached, up-to-the-millisecond `IOBluetoothDevice` state from `bluetoothd`.
    private nonisolated static func queryBatteryViaFreshSubprocess(query: String) -> Int? {
        guard let dylibPath = helperDylibPath() else { return nil }

        let perlScript = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0x01) or exit(1);
        my $sym = DynaLoader::dl_find_symbol($lib, "island_bt_print_battery_percent") or exit(1);
        DynaLoader::dl_install_xsub("main::bt_pct", $sym);
        bt_pct();
        """

        let proc = Process()
        let outPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = ["-e", perlScript, dylibPath]
        var env = ProcessInfo.processInfo.environment
        env["ISLAND_BT_QUERY"] = query
        proc.environment = env
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let val = Int(str),
               val > 0 && val <= 100 {
                return val
            }
        } catch {
            return nil
        }
        return nil
    }

    private nonisolated static func queryBatteryViaNativeBridge(query: String) -> Int? {
        guard let dylibPath = helperDylibPath(),
              let handle = dlopen(dylibPath, RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }

        typealias GetBatteryFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
        guard let sym = dlsym(handle, "island_bt_get_battery_percent") else {
            return nil
        }
        let fn = unsafeBitCast(sym, to: GetBatteryFn.self)
        let pct = query.withCString { cStr in
            fn(cStr)
        }
        if pct > 0 && pct <= 100 {
            return Int(pct)
        }
        return nil
    }
}
