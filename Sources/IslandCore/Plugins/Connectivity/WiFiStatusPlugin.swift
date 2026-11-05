import CoreLocation
import CoreWLAN
import Foundation
import Network
import SwiftUI

public struct WiFiStatusBannerView: View {
    public let isConnected: Bool
    public let networkName: String?
    @Environment(\.notchDeadZoneWidth) private var notchDeadZoneWidth
    @Environment(\.notchWingSizes) private var wingSizes

    public init(isConnected: Bool, networkName: String? = nil) {
        self.isConnected = isConnected
        self.networkName = networkName
    }

    public var body: some View {
        NotchSplitWingContainer(
            leftWingWidth: wingSizes.leftWidth,
            physicalNotchWidth: notchDeadZoneWidth,
            rightWingWidth: wingSizes.rightWidth
        ) {
            HStack(spacing: 6) {
                Image(systemName: isConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isConnected ? .cyan : .secondary)
                    .contentTransition(.symbolEffect(.replace))

                Text("Wi-Fi")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } trailing: {
            Text(statusSubtitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isConnected ? .cyan : .white.opacity(0.55))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusSubtitle: String {
        if isConnected {
            if let ssid = networkName, !ssid.isEmpty {
                return ssid
            }
            return "Connected"
        }
        return "Off"
    }
}

@MainActor
public final class WiFiStatusPlugin: NSObject, ObservableObject, NotchPlugin, CLLocationManagerDelegate {
    public let id = "com.island.plugin.wifi"
    public let displayName = "Wi-Fi Connectivity"
    public let symbolName = "wifi"
    @Published public var isEnabled: Bool = true
    @Published public var hudDuration: Double {
        didSet {
            UserDefaults.standard.set(hudDuration, forKey: "island.wifi.hudDuration")
        }
    }

    private weak var coordinator: NotchStateCoordinator?
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.island.wifi.monitor")
    private var lastConnectedState: Bool?
    private let locationManager = CLLocationManager()

    public override init() {
        let saved = UserDefaults.standard.object(forKey: "island.plugin.com.island.plugin.wifi.enabled") as? Bool ?? true
        self.isEnabled = saved
        self.hudDuration = UserDefaults.standard.object(forKey: "island.wifi.hudDuration") as? Double ?? 2.5
        super.init()
        locationManager.delegate = self
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        stop()

        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let previous = self.lastConnectedState, previous != connected {
                    self.lastConnectedState = connected
                    if connected {
                        // Poll briefly so CoreWLAN has the associated SSID ready right after the interface comes up
                        var ssid = Self.resolveCurrentSSID()
                        if ssid == nil {
                            for _ in 1...6 {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                if let resolved = Self.resolveCurrentSSID() {
                                    ssid = resolved
                                    break
                                }
                            }
                        }
                        self.presentWiFiStatus(isConnected: true, ssid: ssid)
                    } else {
                        self.presentWiFiStatus(isConnected: false, ssid: nil)
                    }
                } else if self.lastConnectedState == nil {
                    self.lastConnectedState = connected
                }
            }
        }
        monitor.start(queue: monitorQueue)
        self.pathMonitor = monitor
    }

    public func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    public func presentWiFiStatus(isConnected: Bool, ssid: String? = nil) {
        guard isEnabled, let coordinator else { return }
        let resolvedSSID = isConnected ? (ssid ?? Self.resolveCurrentSSID()) : nil
        let view = WiFiStatusBannerView(isConnected: isConnected, networkName: resolvedSSID)
        let labelText = isConnected ? (resolvedSSID?.isEmpty == false ? resolvedSSID! : "Connected") : "Off"
        let estimatedTextWidth = CGFloat(labelText.count) * 7.2 + 22
        let rightWidth: CGFloat = isConnected ? min(150, max(86, estimatedTextWidth)) : 44
        let payload = NotchActivityPayload(
            pluginID: id,
            priority: .normal,
            posture: .transientHUD,
            duration: hudDuration,
            wingSizes: NotchWingSizes(leftWidth: 72, rightWidth: rightWidth),
            hudView: AnyView(view),
            accentColor: isConnected ? .cyan : .gray
        )
        coordinator.presentTransientHUD(payload)
        IslandLogger.system.info("Presented Wi-Fi status HUD (connected: \(isConnected), ssid: \(resolvedSSID ?? "nil", privacy: .public))")
    }

    public nonisolated static func resolveCurrentSSID() -> String? {
        if let cwSSID = CWWiFiClient.shared().interface()?.ssid(), !cwSSID.isEmpty {
            return cwSSID
        }

        // Fallback via `networksetup -getairportnetwork en0` (and en1) when CoreWLAN omits SSID without Location Services
        for interface in ["en0", "en1"] {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            proc.arguments = ["-getairportnetwork", interface]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let range = output.range(of: "Current Wi-Fi Network: ") {
                    let parsed = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !parsed.isEmpty && !parsed.lowercased().contains("not associated") {
                        return parsed
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
