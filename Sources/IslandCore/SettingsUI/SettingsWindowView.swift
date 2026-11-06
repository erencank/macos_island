import AppKit
import SwiftUI

public enum SettingsSidebarTab: String, CaseIterable, Identifiable {
    case general
    case battery
    case connectivity
    case appNotifications
    case display
    case sound
    case nowPlaying
    case lockScreen
    case simulator
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .battery: return "Battery"
        case .connectivity: return "Connectivity"
        case .appNotifications: return "Apps"
        case .display: return "Display"
        case .sound: return "Sound"
        case .nowPlaying: return "Now Playing"
        case .lockScreen: return "Lock Screen"
        case .simulator: return "Simulator"
        case .about: return "About"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .battery: return "bolt.fill"
        case .connectivity: return "headphones"
        case .appNotifications: return "bell.badge.fill"
        case .display: return "sun.max.fill"
        case .sound: return "speaker.wave.2.fill"
        case .nowPlaying: return "play.fill"
        case .lockScreen: return "lock.fill"
        case .simulator: return "sparkles"
        case .about: return "info.circle.fill"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .general: return Color(white: 0.42)
        case .battery: return Color(red: 0.96, green: 0.54, blue: 0.30)
        case .connectivity: return Color(red: 0.16, green: 0.80, blue: 0.56)
        case .appNotifications: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .display: return Color(red: 0.56, green: 0.34, blue: 0.94)
        case .sound: return Color(red: 0.92, green: 0.30, blue: 0.84)
        case .nowPlaying: return Color(red: 0.95, green: 0.32, blue: 0.40)
        case .lockScreen: return Color(white: 0.22)
        case .simulator: return Color(red: 0.24, green: 0.78, blue: 0.72)
        case .about: return Color(white: 0.42)
        }
    }
}

private enum SettingsTheme {
    static let windowBackground = Color(red: 0.10, green: 0.105, blue: 0.12)
    static let sidebarBackground = Color(red: 0.115, green: 0.12, blue: 0.135)
    static let detailBackground = Color(red: 0.11, green: 0.115, blue: 0.13)
    static let cardBackground = Color(red: 0.145, green: 0.15, blue: 0.17)
    static let cardBorder = Color.white.opacity(0.08)
    static let rowDivider = Color.white.opacity(0.07)
    static let accentTeal = Color(red: 0.25, green: 0.88, blue: 0.72)
    static let tileBackground = Color(red: 0.19, green: 0.20, blue: 0.22)
    static let tileSelectedFill = Color(red: 0.20, green: 0.29, blue: 0.29)
}

@MainActor
public struct SettingsWindowView: View {
    @ObservedObject public var coordinator: NotchStateCoordinator
    @ObservedObject public var geometryMonitor: ScreenGeometryMonitor
    @ObservedObject public var registry: NotchPluginRegistry
    @ObservedObject public var hudPlugin: SystemHUDPlugin
    @ObservedObject public var nowPlayingPlugin: NowPlayingPlugin
    @ObservedObject public var lockPlugin: LockScreenPlugin
    @ObservedObject public var batteryPlugin: BatteryPowerPlugin
    @ObservedObject public var wifiPlugin: WiFiStatusPlugin
    @ObservedObject public var bluetoothPlugin: BluetoothStatusPlugin
    @ObservedObject public var airDropPlugin: AirDropPlugin
    @ObservedObject public var notificationPlugin: NotificationBridgePlugin
    @ObservedObject public var accessibilityManager: AccessibilityManager

    @State private var selectedTab: SettingsSidebarTab = .general
    @State private var showSoundPermissionPopover = false
    @State private var showDisplayPermissionPopover = false

    public init(
        coordinator: NotchStateCoordinator,
        geometryMonitor: ScreenGeometryMonitor,
        registry: NotchPluginRegistry,
        hudPlugin: SystemHUDPlugin,
        nowPlayingPlugin: NowPlayingPlugin,
        lockPlugin: LockScreenPlugin,
        batteryPlugin: BatteryPowerPlugin,
        wifiPlugin: WiFiStatusPlugin,
        bluetoothPlugin: BluetoothStatusPlugin,
        airDropPlugin: AirDropPlugin,
        notificationPlugin: NotificationBridgePlugin,
        accessibilityManager: AccessibilityManager
    ) {
        self.coordinator = coordinator
        self.geometryMonitor = geometryMonitor
        self.registry = registry
        self.hudPlugin = hudPlugin
        self.nowPlayingPlugin = nowPlayingPlugin
        self.lockPlugin = lockPlugin
        self.batteryPlugin = batteryPlugin
        self.wifiPlugin = wifiPlugin
        self.bluetoothPlugin = bluetoothPlugin
        self.airDropPlugin = airDropPlugin
        self.notificationPlugin = notificationPlugin
        self.accessibilityManager = accessibilityManager
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: 215)
                .background(SettingsTheme.sidebarBackground)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                detailHeader(for: selectedTab)
                    .padding(.horizontal, 26)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        detailContent(for: selectedTab)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.detailBackground)
        }
        .frame(width: 720, height: 580)
        .tint(SettingsTheme.accentTeal)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Space for window traffic lights
            Spacer()
                .frame(height: 32)

            sidebarRow(.general)

            sidebarSectionHeader("Notifications")
            sidebarRow(.battery)
            sidebarRow(.connectivity)
            sidebarRow(.appNotifications)
            sidebarRow(.display)
            sidebarRow(.sound)

            sidebarSectionHeader("Live Activities")
            sidebarRow(.nowPlaying)
            sidebarRow(.lockScreen)

            sidebarSectionHeader("Island")
            sidebarRow(.simulator)
            sidebarRow(.about)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.42))
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func sidebarRow(_ tab: SettingsSidebarTab) -> some View {
        let isSelected = (selectedTab == tab)
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(tab.badgeColor)
                        .frame(width: 24, height: 24)
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(.white.opacity(isSelected ? 1.0 : 0.85))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.11) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Header

    private func detailHeader(for tab: SettingsSidebarTab) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tab.badgeColor)
                    .frame(width: 26, height: 26)
                Image(systemName: tab.symbolName)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
            }

            Text(tab.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            Spacer()
        }
    }

    @ViewBuilder
    private func detailContent(for tab: SettingsSidebarTab) -> some View {
        switch tab {
        case .general:
            generalPane
        case .battery:
            batteryPane
        case .connectivity:
            connectivityPane
        case .appNotifications:
            appNotificationsPane
        case .display:
            displayPane
        case .sound:
            soundPane
        case .nowPlaying:
            nowPlayingPane
        case .lockScreen:
            lockScreenPane
        case .simulator:
            simulatorPane
        case .about:
            aboutPane
        }
    }

    // MARK: - 1. General Pane

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard {
                settingsToggleRow(
                    title: "Hide from screen capture",
                    isOn: $coordinator.hideFromScreenCapture
                )
                rowDivider
                settingsToggleRow(
                    title: "Force simulated notch",
                    isOn: $coordinator.forceSimulatedNotch
                )
                rowDivider
                HStack {
                    Text("Display on")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "display")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                        Picker("", selection: $geometryMonitor.selectionMode) {
                            ForEach(DisplaySelectionMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                if geometryMonitor.selectionMode == .specificDisplay {
                    rowDivider
                    HStack {
                        Text("Monitor")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { geometryMonitor.preferredDisplayID ?? geometryMonitor.activeGeometry.displayID },
                            set: { geometryMonitor.preferredDisplayID = $0 }
                        )) {
                            ForEach(geometryMonitor.availableScreens, id: \.displayID) { screen in
                                Text("\(screen.localizedName) (\(Int(screen.screenFrame.width))×\(Int(screen.screenFrame.height)))")
                                    .tag(screen.displayID)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
            }

            // Idle Activity
            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Idle Activity")
                settingsCard {
                    HStack(spacing: 12) {
                        selectionTile(
                            title: "None",
                            isSelected: !nowPlayingPlugin.isEnabled
                        ) {
                            registry.setPluginEnabled(id: nowPlayingPlugin.id, isEnabled: false)
                        } content: {
                            Image(systemName: "nosign")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white.opacity(0.55))
                        }

                        selectionTile(
                            title: "Playing",
                            isSelected: nowPlayingPlugin.isEnabled
                        ) {
                            registry.setPluginEnabled(id: nowPlayingPlugin.id, isEnabled: true)
                        } content: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(red: 0.95, green: 0.32, blue: 0.40))
                                    .frame(width: 24, height: 24)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(14)
                }
            }

            // Behaviour
            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Behaviour")
                settingsCard {
                    settingsToggleRow(
                        title: "Contrast outline",
                        isOn: $coordinator.showContrastOutline
                    )
                    rowDivider
                    settingsToggleRow(
                        title: "Haptic feedback",
                        isOn: $coordinator.hapticFeedbackEnabled
                    )
                    rowDivider
                    settingsToggleRow(
                        title: "Expand on hover",
                        isOn: $coordinator.expandOnHoverEnabled
                    )
                    rowDivider
                    settingsSliderRow(
                        title: "Hover duration",
                        badgeText: String(format: "%.2f s", coordinator.hoverExpandDelayMs / 1000.0),
                        value: $coordinator.hoverExpandDelayMs,
                        range: 0...300,
                        step: 10
                    )
                    rowDivider
                    settingsSliderRow(
                        title: "Expanded hover exit distance",
                        badgeText: "\(Int(coordinator.hoverExitMarginPx)) px",
                        value: $coordinator.hoverExitMarginPx,
                        range: 8...140,
                        step: 2
                    )
                }
            }

            // Gestures
            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Gestures")
                settingsCard {
                    settingsToggleRow(
                        title: "Swipe to dismiss activity",
                        isOn: $coordinator.swipeToDismissEnabled
                    )
                    rowDivider
                    settingsToggleRow(
                        title: "Swipe to skip media",
                        isOn: $coordinator.swipeToSkipMediaEnabled
                    )
                }
            }

            // Tuning
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    groupTitle("Tuning")
                    Spacer()
                    if coordinator.notchWidthOffsetPx != 0 || coordinator.notchHeightOffsetPx != 0 {
                        Button {
                            coordinator.notchWidthOffsetPx = 0
                            coordinator.notchHeightOffsetPx = 0
                        } label: {
                            Text("Reset to 0 px")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(SettingsTheme.accentTeal)
                        }
                        .buttonStyle(.plain)
                    }
                }
                settingsCard {
                    let widthVal = Int(coordinator.notchWidthOffsetPx.rounded())
                    settingsSliderRow(
                        title: "Notch width",
                        badgeText: widthVal > 0 ? "+\(widthVal) px" : "\(widthVal) px",
                        value: $coordinator.notchWidthOffsetPx,
                        range: -16...24,
                        step: 1,
                        onEditingChanged: { editing in
                            if editing { coordinator.triggerTuningPreview(.width) }
                        }
                    )
                    rowDivider
                    let heightVal = Int(coordinator.notchHeightOffsetPx.rounded())
                    settingsSliderRow(
                        title: "Notch height",
                        badgeText: heightVal > 0 ? "+\(heightVal) px" : "\(heightVal) px",
                        value: $coordinator.notchHeightOffsetPx,
                        range: -12...20,
                        step: 1,
                        onEditingChanged: { editing in
                            if editing { coordinator.triggerTuningPreview(.height) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - 2. Battery Pane

    private var batteryPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard {
                settingsMasterToggleRow(
                    icon: "bolt.fill",
                    iconColor: Color(red: 0.96, green: 0.54, blue: 0.30),
                    title: "Battery",
                    isOn: Binding(
                        get: { batteryPlugin.isEnabled },
                        set: { registry.setPluginEnabled(id: batteryPlugin.id, isEnabled: $0) }
                    )
                )
                rowDivider
                settingsSliderRow(
                    title: "Duration",
                    badgeText: String(format: "%.1f s", batteryPlugin.hudDuration),
                    value: $batteryPlugin.hudDuration,
                    range: 1.0...6.0,
                    step: 0.5
                )
                rowDivider
                settingsToggleRow(
                    title: "Notify on charger connected",
                    isOn: $batteryPlugin.notifyOnChargerConnected
                )
                rowDivider
                settingsToggleRow(
                    title: "Notify on Low Power Mode",
                    isOn: $batteryPlugin.notifyOnLowPowerMode
                )
                rowDivider
                settingsSliderRow(
                    title: "Low battery threshold",
                    badgeText: "\(Int(batteryPlugin.lowBatteryThreshold))%",
                    value: $batteryPlugin.lowBatteryThreshold,
                    range: 5...40,
                    step: 5
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Preview")
                HStack(spacing: 10) {
                    simButton(title: "Test Charging (78%)", icon: "bolt.batteryblock.fill") {
                        batteryPlugin.presentPowerEvent(.charging(percentage: 78))
                    }
                    simButton(title: "Test Low Battery (15%)", icon: "battery.25percent") {
                        batteryPlugin.presentPowerEvent(.lowBattery(percentage: 15))
                    }
                }
            }
        }
    }

    // MARK: - 3. Connectivity Pane (Matches Alcove Screenshot 3)

    private var connectivityPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard {
                settingsMasterToggleRow(
                    icon: "headphones",
                    iconColor: SettingsTheme.accentTeal,
                    title: "Connectivity",
                    isOn: Binding(
                        get: { bluetoothPlugin.isEnabled },
                        set: {
                            registry.setPluginEnabled(id: bluetoothPlugin.id, isEnabled: $0)
                            registry.setPluginEnabled(id: wifiPlugin.id, isEnabled: $0)
                        }
                    )
                )
                rowDivider
                settingsSliderRow(
                    title: "Duration",
                    badgeText: String(format: "%.1f s", bluetoothPlugin.hudDuration),
                    value: Binding(
                        get: { bluetoothPlugin.hudDuration },
                        set: {
                            bluetoothPlugin.hudDuration = $0
                            wifiPlugin.hudDuration = $0
                        }
                    ),
                    range: 1.0...6.0,
                    step: 0.5
                )
                rowDivider
                settingsToggleRow(
                    title: "Warn on low battery",
                    isOn: $bluetoothPlugin.warnOnLowBattery
                )
                rowDivider
                settingsSliderRow(
                    title: "Low battery threshold",
                    badgeText: "\(Int(bluetoothPlugin.lowBatteryThreshold))%",
                    value: $bluetoothPlugin.lowBatteryThreshold,
                    range: 5...50,
                    step: 5
                )
                rowDivider
                settingsToggleRow(
                    title: "Wi-Fi status notifications",
                    isOn: Binding(
                        get: { wifiPlugin.isEnabled },
                        set: { registry.setPluginEnabled(id: wifiPlugin.id, isEnabled: $0) }
                    )
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("AirDrop")
                settingsCard {
                    settingsMasterToggleRow(
                        icon: "airplayaudio",
                        iconColor: .cyan,
                        title: "AirDrop Receiver",
                        isOn: Binding(
                            get: { airDropPlugin.isEnabled },
                            set: { registry.setPluginEnabled(id: airDropPlugin.id, isEnabled: $0) }
                        )
                    )
                    rowDivider
                    settingsToggleRow(
                        title: "Replace system AirDrop notification",
                        isOn: $airDropPlugin.replaceSystemNotification
                    )
                    rowDivider
                    settingsToggleRow(
                        title: "Automatically open received web links",
                        isOn: $airDropPlugin.autoOpenLinks
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Preview")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    simButton(title: "Test Connected Bluetooth", icon: "headphones") {
                        bluetoothPlugin.triggerConnectedDevicePreview()
                    }
                    simButton(title: "Test Wi-Fi Connected", icon: "wifi") {
                        wifiPlugin.presentWiFiStatus(isConnected: true, ssid: "Home-5G")
                    }
                    simButton(title: "Simulate AirDrop File", icon: "airplayaudio") {
                        airDropPlugin.simulateIncomingFileRequest()
                    }
                    simButton(title: "Simulate AirDrop Link", icon: "safari.fill") {
                        airDropPlugin.simulateIncomingLinkRequest()
                    }
                }
            }
        }
    }

    // MARK: - App Notifications Pane

    private var appNotificationsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                groupTitle("App Notifications")
                settingsCard {
                    settingsMasterToggleRow(
                        icon: "bell.badge.fill",
                        iconColor: .orange,
                        title: "Show app notifications in Island",
                        isOn: Binding(
                            get: { notificationPlugin.isEnabled },
                            set: { registry.setPluginEnabled(id: notificationPlugin.id, isEnabled: $0) }
                        )
                    )
                    rowDivider
                    settingsToggleRow(title: "Slack messages", isOn: $notificationPlugin.slackEnabled)
                    rowDivider
                    settingsToggleRow(title: "Hide system banner for Slack", isOn: $notificationPlugin.hideSlackBanner)
                    rowDivider
                    settingsToggleRow(title: "Microsoft Teams messages and calls", isOn: $notificationPlugin.teamsEnabled)
                    rowDivider
                    settingsToggleRow(title: "Hide system banner for Teams", isOn: $notificationPlugin.hideTeamsBanner)
                    rowDivider
                    settingsToggleRow(title: "Outlook emails", isOn: $notificationPlugin.outlookEnabled)
                    rowDivider
                    settingsToggleRow(title: "Hide system banner for Outlook", isOn: $notificationPlugin.hideOutlookBanner)
                    rowDivider
                    settingsToggleRow(title: "Other apps (generic)", isOn: $notificationPlugin.otherAppsEnabled)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Preview")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    simButton(title: "Simulate Slack Message", icon: "number") {
                        notificationPlugin.simulateSlackMessage()
                    }
                    simButton(title: "Simulate Teams Call", icon: "phone.fill") {
                        notificationPlugin.simulateTeamsCall()
                    }
                    simButton(title: "Simulate Outlook Email", icon: "envelope.fill") {
                        notificationPlugin.simulateOutlookEmail()
                    }
                    simButton(title: "Dump Notification Tree", icon: "doc.text.magnifyingglass") {
                        notificationPlugin.revealAccessibilityTreeDump()
                    }
                }
            }
        }
    }

    // MARK: - 4. Display Pane

    private var displayPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard {
                HStack {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.56, green: 0.34, blue: 0.94))
                        .frame(width: 20)
                    Text("Display")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                    Spacer()
                    if !accessibilityManager.isTrusted {
                        Button {
                            showDisplayPermissionPopover = true
                        } label: {
                            Image(systemName: "hand.raised.slash.fill")
                                .font(.system(size: 12.5))
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle("", isOn: Binding(
                        get: { hudPlugin.replaceDisplayHUD },
                        set: { newValue in
                            if newValue && !accessibilityManager.isTrusted {
                                showDisplayPermissionPopover = true
                            }
                            hudPlugin.replaceDisplayHUD = newValue
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .popover(isPresented: $showDisplayPermissionPopover, arrowEdge: .top) {
                    HUDPermissionPopoverView(accessibilityManager: accessibilityManager) {
                        showDisplayPermissionPopover = false
                    }
                }

                rowDivider
                settingsSliderRow(
                    title: "Duration",
                    badgeText: String(format: "%.1f s", hudPlugin.hudDuration),
                    value: $hudPlugin.hudDuration,
                    range: 0.8...4.0,
                    step: 0.2
                )
                rowDivider
                HStack(spacing: 12) {
                    selectionTile(
                        title: "Monochrome",
                        isSelected: !hudPlugin.useColoredProgressBar
                    ) {
                        hudPlugin.useColoredProgressBar = false
                    } content: {
                        miniProgressBarPreview(colors: [.white, .white])
                    }

                    selectionTile(
                        title: "Colored",
                        isSelected: hudPlugin.useColoredProgressBar
                    ) {
                        hudPlugin.useColoredProgressBar = true
                    } content: {
                        miniProgressBarPreview(colors: [
                            Color(red: 0.98, green: 0.78, blue: 0.28),
                            Color(red: 0.98, green: 0.78, blue: 0.28)
                        ])
                    }
                }
                .padding(14)
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Preview")
                simButton(title: "Test Display HUD (80%)", icon: "sun.max.fill") {
                    hudPlugin.presentHUD(kind: .display(level: 0.80))
                }
            }
        }
    }

    // MARK: - 5. Sound Pane

    private var soundPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.92, green: 0.30, blue: 0.84))
                        .frame(width: 20)
                    Text("Sound")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                    Spacer()
                    if !accessibilityManager.isTrusted {
                        Button {
                            showSoundPermissionPopover = true
                        } label: {
                            Image(systemName: "hand.raised.slash.fill")
                                .font(.system(size: 12.5))
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle("", isOn: Binding(
                        get: { hudPlugin.replaceSoundHUD },
                        set: { newValue in
                            if newValue && !accessibilityManager.isTrusted {
                                showSoundPermissionPopover = true
                            }
                            hudPlugin.replaceSoundHUD = newValue
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .popover(isPresented: $showSoundPermissionPopover, arrowEdge: .top) {
                    HUDPermissionPopoverView(accessibilityManager: accessibilityManager) {
                        showSoundPermissionPopover = false
                    }
                }

                rowDivider
                settingsSliderRow(
                    title: "Duration",
                    badgeText: String(format: "%.1f s", hudPlugin.hudDuration),
                    value: $hudPlugin.hudDuration,
                    range: 0.8...4.0,
                    step: 0.2
                )
                rowDivider
                HStack(spacing: 12) {
                    selectionTile(
                        title: "Monochrome",
                        isSelected: !hudPlugin.useColoredProgressBar
                    ) {
                        hudPlugin.useColoredProgressBar = false
                    } content: {
                        miniProgressBarPreview(colors: [.white, .white])
                    }

                    selectionTile(
                        title: "Colored",
                        isSelected: hudPlugin.useColoredProgressBar
                    ) {
                        hudPlugin.useColoredProgressBar = true
                    } content: {
                        miniProgressBarPreview(colors: [SettingsTheme.accentTeal, SettingsTheme.accentTeal])
                    }
                }
                .padding(14)
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Preview")
                simButton(title: "Test Sound HUD (65%)", icon: "speaker.wave.2.fill") {
                    hudPlugin.presentHUD(kind: .sound(level: 0.65, isMuted: false))
                }
            }
        }
    }

    // MARK: - 6. Now Playing Pane (Matches Alcove Screenshot 2)

    private var nowPlayingPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard {
                settingsMasterToggleRow(
                    icon: "play.fill",
                    iconColor: SettingsTheme.accentTeal,
                    title: "Now Playing",
                    isOn: Binding(
                        get: { nowPlayingPlugin.isEnabled },
                        set: { registry.setPluginEnabled(id: nowPlayingPlugin.id, isEnabled: $0) }
                    )
                )
                rowDivider

                // Theme Style Selector (Monochrome / Colored / Gradient)
                HStack(spacing: 12) {
                    selectionTile(
                        title: "Monochrome",
                        isSelected: nowPlayingPlugin.themeStyle == .monochrome
                    ) {
                        nowPlayingPlugin.themeStyle = .monochrome
                    } content: {
                        miniProgressBarPreview(colors: [.white.opacity(0.85), .white.opacity(0.85)])
                    }

                    selectionTile(
                        title: "Colored",
                        isSelected: nowPlayingPlugin.themeStyle == .colored
                    ) {
                        nowPlayingPlugin.themeStyle = .colored
                    } content: {
                        miniProgressBarPreview(colors: [SettingsTheme.accentTeal, SettingsTheme.accentTeal])
                    }

                    selectionTile(
                        title: "Gradient",
                        isSelected: nowPlayingPlugin.themeStyle == .gradient
                    ) {
                        nowPlayingPlugin.themeStyle = .gradient
                    } content: {
                        miniProgressBarPreview(colors: [
                            SettingsTheme.accentTeal,
                            Color(red: 0.96, green: 0.68, blue: 0.48)
                        ])
                    }
                }
                .padding(14)

                rowDivider
                settingsToggleRow(
                    title: "Keep compact wings visible when paused",
                    isOn: $nowPlayingPlugin.showWhenPaused
                )
                rowDivider
                settingsToggleRow(
                    title: "Disable compact waveform",
                    isOn: $nowPlayingPlugin.disableCompactWaveform
                )
                rowDivider
                settingsToggleRow(
                    title: "Hide while source app is active",
                    isOn: $nowPlayingPlugin.hideWhileSourceAppActive
                )
                rowDivider

                // Auxiliary Button Selector (Favorite / Shuffle / Repeat / Copy)
                HStack(spacing: 10) {
                    ForEach(NowPlayingAuxiliaryAction.allCases) { action in
                        selectionTile(
                            title: action.title,
                            isSelected: nowPlayingPlugin.auxiliaryAction == action
                        ) {
                            nowPlayingPlugin.auxiliaryAction = action
                        } content: {
                            Image(systemName: action.symbolName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(
                                    nowPlayingPlugin.auxiliaryAction == action
                                        ? SettingsTheme.accentTeal
                                        : .white.opacity(0.65)
                                )
                        }
                    }
                }
                .padding(14)
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Preview")
                HStack(spacing: 10) {
                    simButton(title: "Simulate 'blue jean' Track", icon: "music.note") {
                        nowPlayingPlugin.simulateTrack()
                    }
                    simButton(title: "Clear Simulated Track", icon: "xmark.circle") {
                        nowPlayingPlugin.clearSimulatedTrack()
                    }
                }
            }
        }
    }

    // MARK: - 7. Lock Screen Pane

    private var lockScreenPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard {
                settingsMasterToggleRow(
                    icon: "lock.fill",
                    iconColor: .orange,
                    title: "Lock Screen",
                    isOn: Binding(
                        get: { lockPlugin.isEnabled },
                        set: { registry.setPluginEnabled(id: lockPlugin.id, isEnabled: $0) }
                    )
                )
                rowDivider
                settingsSliderRow(
                    title: "Duration",
                    badgeText: String(format: "%.1f s", lockPlugin.hudDuration),
                    value: $lockPlugin.hudDuration,
                    range: 1.0...5.0,
                    step: 0.2
                )
                rowDivider
                settingsToggleRow(
                    title: "Show notification on unlock",
                    isOn: $lockPlugin.showOnUnlock
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                groupTitle("Preview")
                HStack(spacing: 10) {
                    simButton(title: "Test Lock Transition", icon: "lock.fill") {
                        lockPlugin.presentLockTransition(isLocked: true)
                    }
                    simButton(title: "Test Unlock Transition", icon: "lock.open.fill") {
                        lockPlugin.presentLockTransition(isLocked: false)
                    }
                }
            }
        }
    }

    // MARK: - 8. Simulator Pane

    private var simulatorPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trigger any Dynamic Island notification or live activity on demand to preview animations and layout.")
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.62))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                simButton(title: "Test Sound HUD (65%)", icon: "speaker.wave.2.fill") {
                    hudPlugin.presentHUD(kind: .sound(level: 0.65, isMuted: false))
                }
                simButton(title: "Test Display HUD (80%)", icon: "sun.max.fill") {
                    hudPlugin.presentHUD(kind: .display(level: 0.80))
                }
                simButton(title: "Simulate 'blue jean' Track", icon: "music.note") {
                    nowPlayingPlugin.simulateTrack()
                }
                simButton(title: "Test Lock Screen Widget", icon: "lock.open.fill") {
                    lockPlugin.presentLockTransition(isLocked: true)
                }
                simButton(title: "Test Low Battery (15%)", icon: "battery.25percent") {
                    batteryPlugin.presentPowerEvent(.lowBattery(percentage: 15))
                }
                simButton(title: "Test Energy Saver On", icon: "bolt.shield.fill") {
                    batteryPlugin.presentPowerEvent(.lowPowerMode(enabled: true, percentage: 64))
                }
                simButton(title: "Test Wi-Fi Connected", icon: "wifi") {
                    wifiPlugin.presentWiFiStatus(isConnected: true, ssid: "Home-5G")
                }
                simButton(title: "Test Connected Bluetooth", icon: "headphones") {
                    bluetoothPlugin.triggerConnectedDevicePreview()
                }
                simButton(title: "Simulate AirDrop File", icon: "airplayaudio") {
                    airDropPlugin.simulateIncomingFileRequest()
                }
                simButton(title: "Simulate AirDrop Link", icon: "safari.fill") {
                    airDropPlugin.simulateIncomingLinkRequest()
                }
                simButton(title: "Test Bluetooth Disconnected", icon: "headphones") {
                    bluetoothPlugin.presentBluetoothEvent(
                        BluetoothStatusEvent(
                            deviceName: "Bluetooth Headphones",
                            category: .headphones,
                            isConnected: false,
                            batteryPercentage: nil
                        )
                    )
                }
                simButton(title: "Clear Simulated Track", icon: "xmark.circle") {
                    nowPlayingPlugin.clearSimulatedTrack()
                }
            }
        }
    }

    // MARK: - 9. About Pane

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.18, green: 0.72, blue: 0.64),
                                        Color(red: 0.14, green: 0.42, blue: 0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 52, height: 52)

                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black)
                            .frame(width: 28, height: 11)
                            .offset(y: -12)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Island for macOS")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text("Version 1.2.0 • Native Apple Silicon Dynamic Island")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.58))
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Circle()
                            .fill(accessibilityManager.isTrusted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(accessibilityManager.isTrusted ? "Accessibility Active" : "Permission Needed")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .padding(16)
            }
        }
    }

    // MARK: - Reusable Alcove-Style Building Blocks

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.58))
            .padding(.leading, 4)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 0.8)
        )
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(SettingsTheme.rowDivider)
            .frame(height: 1)
    }

    private func settingsMasterToggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 18)

            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(.white.opacity(0.95))

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func settingsToggleRow(
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.90))

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func settingsSliderRow(
        title: String,
        badgeText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.90))

                Spacer()

                Text(badgeText)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
                    )
            }

            Slider(
                value: value,
                in: range,
                step: step,
                onEditingChanged: onEditingChanged
            )
            .tint(SettingsTheme.accentTeal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func selectionTile<Content: View>(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? SettingsTheme.tileSelectedFill : SettingsTheme.tileBackground)
                        .frame(height: 44)

                    content()
                }
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            isSelected ? SettingsTheme.accentTeal : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 2.0 : 0.8
                        )
                )

                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func miniProgressBarPreview(colors: [Color]) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.75))
                .frame(height: 36)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 5)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: colors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.64, height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)
        }
    }

    private func simButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(SettingsTheme.accentTeal)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9.5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}
