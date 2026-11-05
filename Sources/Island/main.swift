import AppKit
import IslandCore
import SwiftUI

@main
@MainActor
final class IslandAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = NotchStateCoordinator()
    private let geometryMonitor = ScreenGeometryMonitor()
    private lazy var registry = NotchPluginRegistry(coordinator: coordinator)

    private let hudPlugin = SystemHUDPlugin()
    private let nowPlayingPlugin = NowPlayingPlugin()
    private let lockPlugin = LockScreenPlugin()
    private let batteryPlugin = BatteryPowerPlugin()
    private let wifiPlugin = WiFiStatusPlugin()
    private let bluetoothPlugin = BluetoothStatusPlugin()
    private let airDropPlugin = AirDropPlugin()

    private var notchWindowController: NotchWindowController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = IslandAppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory menu-bar + notch agent so it doesn't clutter Cmd+Tab,
        // while still able to display its Settings window when requested.
        NSApp.setActivationPolicy(.accessory)

        // Register all modular plugins
        registry.register(hudPlugin)
        registry.register(nowPlayingPlugin)
        registry.register(lockPlugin)
        registry.register(batteryPlugin)
        registry.register(wifiPlugin)
        registry.register(bluetoothPlugin)
        registry.register(airDropPlugin)

        // Create and display the Notch Dynamic Island window
        let mediaService = nowPlayingPlugin.mediaService
        let npPlugin = nowPlayingPlugin
        let windowController = NotchWindowController(
            coordinator: coordinator,
            geometryMonitor: geometryMonitor,
            defaultExpandedContent: {
                AnyView(
                    NowPlayingExpandedCardView(
                        mediaService: mediaService,
                        themeStyle: npPlugin.themeStyle,
                        auxiliaryAction: npPlugin.auxiliaryAction
                    )
                )
            }
        )
        windowController.show()
        self.notchWindowController = windowController

        setupMenuBarExtraItem()

        if CommandLine.arguments.contains("--open-settings") {
            openSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.stopAll()
        notchWindowController?.close()
    }

    private func setupMenuBarExtraItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Island")
            button.toolTip = "Island — MacBook Dynamic Island"
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Island Settings & Simulator...", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let demoTrackItem = NSMenuItem(title: "Simulate 'blue jean' Music Track", action: #selector(triggerDemoTrack), keyEquivalent: "m")
        demoTrackItem.target = self
        menu.addItem(demoTrackItem)

        let demoSoundItem = NSMenuItem(title: "Test Sound HUD in Notch", action: #selector(triggerDemoSoundHUD), keyEquivalent: "s")
        demoSoundItem.target = self
        menu.addItem(demoSoundItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Island", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func triggerDemoTrack() {
        nowPlayingPlugin.simulateTrack()
    }

    @objc private func triggerDemoSoundHUD() {
        hudPlugin.presentHUD(kind: .sound(level: 0.72, isMuted: false))
    }

    @objc private func openSettingsWindow() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsWindowView(
            coordinator: coordinator,
            geometryMonitor: geometryMonitor,
            registry: registry,
            hudPlugin: hudPlugin,
            nowPlayingPlugin: nowPlayingPlugin,
            lockPlugin: lockPlugin,
            batteryPlugin: batteryPlugin,
            wifiPlugin: wifiPlugin,
            bluetoothPlugin: bluetoothPlugin,
            airDropPlugin: airDropPlugin,
            accessibilityManager: .shared
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Island Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.115, blue: 0.13, alpha: 1.0)
        window.center()
        window.contentView = NSHostingView(rootView: settingsView)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
