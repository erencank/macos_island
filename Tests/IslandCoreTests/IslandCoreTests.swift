import CoreGraphics
import Foundation
import IOBluetooth
import SwiftUI
@testable import IslandCore

@main
struct IslandTestsRunner {
    static func main() async {
        print("==> Running IslandCore Automated Test Suite...")
        var passed = 0
        var failed = 0

        func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
            if condition() {
                passed += 1
            } else {
                failed += 1
                print("  [FAIL] \(file):\(line) — \(message)")
            }
        }

        // 1. Test Notched MacBook Geometry Calculation
        do {
            let input = ScreenMetricsInput(
                displayID: 1,
                localizedName: "Built-in Retina Display",
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                topSafeAreaInset: 37,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 945, width: 662, height: 37),
                auxiliaryTopRightArea: CGRect(x: 850, y: 945, width: 662, height: 37)
            )
            let geo = NotchGeometry.calculate(from: input)

            check(geo.hasPhysicalNotch == true, "Expected physical notch detected")
            check(geo.notchFrame.origin.x == 662, "Expected notch origin.x == 662")
            check(geo.notchFrame.width == 188, "Expected notch width == 188")
            check(geo.notchFrame.height == 37, "Expected notch height == 37")
            check(geo.notchFrame.maxY == 982, "Expected notch flush with top edge (maxY == 982)")
            check(abs(geo.canvasWindowFrame.midX - geo.notchFrame.midX) < 0.01, "Expected canvas horizontally centered on notch")
            print("  [PASS] testNotchedMacBookGeometryCalculation")
        }

        // 2. Test External Monitor Non-Notched Fallback Pill Calculation
        do {
            let input = ScreenMetricsInput(
                displayID: 2,
                localizedName: "LG UltraFine",
                screenFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                topSafeAreaInset: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            )
            let geo = NotchGeometry.calculate(from: input)

            check(geo.hasPhysicalNotch == false, "Expected non-notched external monitor")
            check(geo.notchFrame.width == NotchGeometry.fallbackPillWidth, "Expected fallback pill width")
            check(geo.notchFrame.height == NotchGeometry.fallbackPillHeight, "Expected fallback pill height")
            check(abs(geo.notchFrame.midX - input.screenFrame.midX) < 0.01, "Expected pill centered on external screen")
            check(geo.notchFrame.maxY == 1440, "Expected pill pinned to top of external screen")
            print("  [PASS] testExternalMonitorNonNotchedFallbackPillCalculation")
        }

        // 3. Test Multi-Monitor Display Selection Modes
        do {
            let builtIn = ScreenMetricsInput(
                displayID: 1,
                localizedName: "Built-in Retina Display",
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                topSafeAreaInset: 37,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 945, width: 662, height: 37),
                auxiliaryTopRightArea: CGRect(x: 850, y: 945, width: 662, height: 37)
            )
            let external = ScreenMetricsInput(
                displayID: 2,
                localizedName: "Studio External",
                screenFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                topSafeAreaInset: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            )
            let screens = [external, builtIn]

            let autoSelected = NotchGeometry.selectScreen(
                from: screens,
                mode: .automaticNotch,
                preferredDisplayID: nil,
                cursorLocation: CGPoint(x: 2000, y: 500)
            )
            check(autoSelected?.displayID == 1, "Automatic mode should select notched display")

            let cursorSelected = NotchGeometry.selectScreen(
                from: screens,
                mode: .followCursor,
                preferredDisplayID: nil,
                cursorLocation: CGPoint(x: 2000, y: 500)
            )
            check(cursorSelected?.displayID == 2, "Follow cursor mode should select display under cursor")

            let specificSelected = NotchGeometry.selectScreen(
                from: screens,
                mode: .specificDisplay,
                preferredDisplayID: 2,
                cursorLocation: CGPoint(x: 100, y: 100)
            )
            check(specificSelected?.displayID == 2, "Specific display mode should select preferredDisplayID")
            print("  [PASS] testMultiMonitorDisplaySelectionModes")
        }

        // 4. Test State Machine Priority Preemption & 50ms Hover Expansion
        await MainActor.run {
            let coordinator = NotchStateCoordinator(hoverExpandDelayMs: 50)
            check(coordinator.posture == .resting, "Initial posture should be .resting")

            let mediaPayload = NotchActivityPayload(
                pluginID: "com.island.plugin.nowplaying",
                priority: .background,
                posture: .compactWings
            )
            coordinator.publishPersistentActivity(mediaPayload)
            check(coordinator.posture == .compactWings, "Publishing persistent activity should enter .compactWings")

            let soundHUD = NotchActivityPayload(
                pluginID: "com.island.plugin.systemhud",
                priority: .high,
                posture: .transientHUD,
                duration: 0.15,
                wingSizes: NotchWingSizes(leftWidth: 78, rightWidth: 76)
            )
            coordinator.presentTransientHUD(soundHUD)
            check(coordinator.posture == .transientHUD, "High-priority HUD should preempt .compactWings")

            let wifiHUD = NotchActivityPayload(
                pluginID: "com.island.plugin.wifi",
                priority: .normal,
                posture: .transientHUD,
                duration: 0.5
            )
            coordinator.presentTransientHUD(wifiHUD)
            check(coordinator.activeTransientHUD?.pluginID == "com.island.plugin.systemhud", "Lower-priority HUD must not preempt active high-priority HUD")

            let baseNotch = CGSize(width: 188, height: 37)
            let hudLayout = coordinator.targetLayout(for: baseNotch, hasPhysicalNotch: true)
            check(hudLayout.leftWingWidth == 78 && hudLayout.rightWingWidth == 76, "Transient HUD should use snug content-fitted wing widths")

            // Test asymmetric wing layout (e.g. Low Battery: leftWing = 108, rightWing = 46)
            let lowBatteryHUD = NotchActivityPayload(
                pluginID: "com.island.plugin.battery",
                priority: .critical,
                posture: .transientHUD,
                duration: 0.15,
                wingSizes: NotchWingSizes(leftWidth: 108, rightWidth: 46)
            )
            coordinator.presentTransientHUD(lowBatteryHUD)
            let asymLayout = coordinator.targetLayout(for: baseNotch, hasPhysicalNotch: true)
            check(asymLayout.leftWingWidth == 108 && asymLayout.rightWingWidth == 46, "Asymmetric HUD should preserve distinct left and right wing widths")
            check(asymLayout.horizontalCenterOffset == (46.0 - 108.0) / 2.0, "Horizontal center offset should shift left so center stays locked on hardware notch")

            // Test Notch Tuning Calibration (Notch width +2px, Notch height -1px) and Hover Exit Margin
            coordinator.notchWidthOffsetPx = 2
            coordinator.notchHeightOffsetPx = -1
            coordinator.hoverExitMarginPx = 48

            let tunedBase = coordinator.tunedBaseNotchSize(for: baseNotch)
            check(tunedBase.width == 190 && tunedBase.height == 36, "Tuned base notch size should apply +2px width and -1px height offsets")
            check(coordinator.activeTuningAxis == .exitMargin, "Adjusting tuning property should activate live calibration overlay")
            check(coordinator.hoverExitMarginPx == 48, "Hover exit margin should persist configured pixel radius")

            coordinator.notchWidthOffsetPx = 0
            coordinator.notchHeightOffsetPx = 0
            coordinator.clearPersistentActivity(pluginID: "com.island.plugin.nowplaying")
        }

        // 5. Test NotchSilhouetteShape Path Generation & Bluetooth Device Categorizer
        do {
            let shape = NotchSilhouetteShape(topEarRadius: 12, bottomCornerRadius: 18)
            let rect = CGRect(x: 0, y: 0, width: 320, height: 42)
            let path = shape.path(in: rect)

            check(!path.isEmpty, "Silhouette path should not be empty")
            check(abs(path.boundingRect.width - 320) <= 1.0, "Path bounding width should match rect")
            check(abs(path.boundingRect.height - 42) <= 1.0, "Path bounding height should match rect")

            check(BluetoothDeviceCategory.categorize(deviceName: "Erencan's AirPods Pro") == .airpodsPro, "Should categorize AirPods Pro")
            check(BluetoothDeviceCategory.categorize(deviceName: "AirPods Max") == .airpodsMax, "Should categorize AirPods Max")
            check(BluetoothDeviceCategory.categorize(deviceName: "Magic Keyboard") == .keyboard, "Should categorize Magic Keyboard")
            check(BluetoothDeviceCategory.categorize(deviceName: "WH-1000XM4") == .headphones, "Should categorize Sony WH-1000XM4 headphones")

            // If a Bluetooth device (e.g. WH-1000XM4) is currently connected on this Mac, verify battery KVC readout
            if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
               let connected = paired.first(where: { $0.isConnected() }) {
                let pct = BluetoothStatusPlugin.resolveBatteryPercentage(
                    address: connected.addressString ?? "",
                    deviceName: connected.nameOrAddress ?? ""
                )
                print("  [INFO] Live connected Bluetooth device '\(connected.nameOrAddress ?? "?")' battery = \(pct.map { "\($0)%" } ?? "nil")")
                check(pct != nil, "Connected Bluetooth device should report non-nil battery percentage")
            }
            print("  [PASS] testStateCoordinatorSilhouetteAndBluetoothCategorizer")
        }

        // 6. Test Incoming AirDrop Receiver State Machine (Expand on Request -> Shrink to Compact Wings on Accept -> Collapse on Decline)
        await MainActor.run {
            let coordinator = NotchStateCoordinator(hoverExpandDelayMs: 50)
            let airDropPlugin = AirDropPlugin()
            airDropPlugin.isEnabled = true
            airDropPlugin.start(coordinator: coordinator)

            // Simulate incoming file transfer request -> should auto-expand to .expandedCard without hover
            airDropPlugin.simulateIncomingFileRequest()
            check(coordinator.posture == .expandedCard, "Incoming AirDrop confirmation should automatically expand the Island into .expandedCard")
            check(airDropPlugin.receiverService.activeSession?.phase == .awaitingConfirmation, "Session phase should be .awaitingConfirmation")

            // Accept transfer -> should transition to .transferring and collapse Island into .compactWings
            airDropPlugin.acceptTransfer()
            check(airDropPlugin.receiverService.activeSession?.phase == .transferring, "Accepting AirDrop should transition session phase to .transferring")
            check(coordinator.posture == .compactWings, "Accepted AirDrop transfer should shrink Island to .compactWings while downloading")

            // Decline/Cancel transfer -> should clear activity and return Island to .resting
            airDropPlugin.declineTransfer()
            check(airDropPlugin.receiverService.activeSession == nil, "Declining AirDrop should clear active session")
            check(coordinator.posture == .resting, "Declining AirDrop should collapse Island back to .resting")

            // Test NotificationCenter AirDrop alert string parser (e.g. "cashyos-desktop would like to share a photo")
            let parsedPhoto = AirDropReceiverService.parseAirDropAlertStrings([
                "AirDrop",
                "cashyos-desktop would like to share a photo",
                "Decline",
                "Accept"
            ])
            check(parsedPhoto.sender == "cashyos-desktop", "Should extract sender name 'cashyos-desktop'")
            check(parsedPhoto.itemTitle == "Photo", "Should extract clean item title 'Photo'")
            check(parsedPhoto.isLink == false, "Photo share should not be marked as link")
            check(parsedPhoto.symbolName == "photo.fill", "Photo share should use photo.fill icon")
            check(parsedPhoto.isIncomingRequest == true, "Banner with 'would like to share' should be marked as incoming request")

            // Test post-transfer completion banner (e.g. "Open" / "Show in Finder" without "would like to share")
            let parsedCompletion = AirDropReceiverService.parseAirDropAlertStrings([
                "AirDrop",
                "preferences.toml",
                "Open",
                "Show in Finder"
            ])
            check(parsedCompletion.isIncomingRequest == false, "Post-download completion banner must not be treated as a new incoming ask request")

            // Test priority preemption between persistent activities (AirDrop .critical over NowPlaying .background)
            let mediaPayload = NotchActivityPayload(
                pluginID: "com.island.plugin.nowplaying",
                priority: .background,
                posture: .compactWings
            )
            coordinator.publishPersistentActivity(mediaPayload)
            check(coordinator.persistentActivity?.pluginID == "com.island.plugin.nowplaying", "Now Playing should be active when alone")

            airDropPlugin.simulateIncomingFileRequest()
            check(coordinator.persistentActivity?.pluginID == airDropPlugin.id, "Critical AirDrop activity must preempt background Now Playing")
            check(coordinator.posture == .expandedCard, "Second incoming AirDrop must expand the Island into .expandedCard")

            // When AirDrop is dismissed, Now Playing should automatically resume as the active persistent activity
            airDropPlugin.declineTransfer()
            check(coordinator.persistentActivity?.pluginID == "com.island.plugin.nowplaying", "Now Playing should resume after AirDrop is dismissed")
            coordinator.clearPersistentActivity(pluginID: "com.island.plugin.nowplaying")

            airDropPlugin.stop()
            print("  [PASS] testIncomingAirDropReceiverStateMachine")
        }

        // Notification parsers
        do {
            let parsers = NotificationParserSet()

            let slackChannel = RawBanner(texts: ["Slack, Alice (#general), Standup moved", "Slack", "Alice (#general)", "Standup moved", "now"])
            let slack = parsers.parse(slackChannel)
            check(slack?.appName == "Slack", "Slack banner should be recognised")
            check(slack?.sender == "Alice", "Slack sender should exclude the channel suffix")
            check(slack?.channel == "#general", "Slack channel should be extracted from parentheses")
            check(slack?.body == "Standup moved", "Slack body should be the last content text")
            check(slack?.headline == "Alice · #general", "Slack headline should join sender and channel")

            let slackIn = parsers.parse(RawBanner(texts: ["Slack", "Bob in #dev", "ship it"]))
            check(slackIn?.sender == "Bob" && slackIn?.channel == "#dev", "Slack 'X in #channel' title should parse")

            let slackDM = parsers.parse(RawBanner(texts: ["Slack", "Carol", "lunch?"]))
            check(slackDM?.sender == "Carol" && slackDM?.channel == nil, "Slack direct message has no channel")

            let call = parsers.parse(RawBanner(
                texts: ["Microsoft Teams", "Bob is calling you", "Accept", "Decline"],
                buttons: [BannerButton(title: "Accept", press: { true }), BannerButton(title: "Decline", press: { true })]
            ))
            check(call?.kind == .incomingCall, "Teams banner with call buttons should be an incoming call")
            check(call?.sender == "Bob", "Teams caller name should be extracted")

            let teamsMessage = parsers.parse(RawBanner(texts: ["Microsoft Teams", "Dana", "See you at 3"]))
            check(teamsMessage?.kind == .message && teamsMessage?.sender == "Dana", "Teams chat banner should be a message")

            let email = parsers.parse(RawBanner(texts: ["Microsoft Outlook, Q4 notes, Dana Lee, See attached", "Q4 notes", "Dana Lee", "See attached"]))
            check(email?.kind == .email && email?.sender == "Dana Lee", "Outlook banner should parse as an email from the sender")
            check(email?.headline == "Dana Lee", "Email headline should be the sender only")
            check(email?.body == "Q4 notes\nSee attached", "Email body should be subject then preview")
            let noPreview = parsers.parse(RawBanner(texts: ["Microsoft Outlook, Lunch?, Dana Lee", "Lunch?", "Dana Lee"]))
            check(noPreview?.body == "Lunch?", "Email without preview should carry only the subject")
            check(parsers.parse(RawBanner(texts: ["Microsoft Outlook", "Weekly sync", "Starts in 5 minutes"])) == nil, "Outlook calendar reminders are ignored")

            let realOutlook = parsers.parse(RawBanner(texts: [
                "Microsoft Outlook, Re: Test hello world, Erencan Kanmaz, CAUTION: This email originated from outside. Hillo",
                "Re: Test hello world",
                "Erencan Kanmaz",
                "CAUTION: This email originated from outside. Hillo"
            ]))
            check(realOutlook?.kind == .email, "Captured real Outlook banner should parse as an email")
            check(realOutlook?.sender == "Erencan Kanmaz", "Captured Outlook banner sender is the subtitle")
            check(realOutlook?.body.hasPrefix("Re: Test hello world\n") == true, "Captured Outlook banner subject is the title")

            check(parsers.parse(RawBanner(texts: ["Mail", "Eve", "Hello"])) == nil, "Unknown apps are not handled by app parsers")
            check(parsers.parseGeneric(RawBanner(texts: ["Mail", "Eve", "Hello"]))?.appName == "Mail", "Generic parser should use first text as app name")
            print("  [PASS] testNotificationParsers")
        }

        // Notification bridge plugin
        do {
            let coordinator = NotchStateCoordinator()
            let plugin = NotificationBridgePlugin()
            plugin.slackEnabled = true
            plugin.teamsEnabled = true
            plugin.otherAppsEnabled = false
            plugin.start(coordinator: coordinator)

            var accepted = false
            let callBanner = RawBanner(
                texts: ["Microsoft Teams", "Bob is calling you", "Accept", "Decline"],
                buttons: [BannerButton(title: "Accept", press: { accepted = true; return true }), BannerButton(title: "Decline", press: { true })]
            )
            plugin.handle(banners: [callBanner])
            check(coordinator.persistentActivity?.pluginID == plugin.id, "Teams call should publish an activity")
            check(coordinator.persistentActivity?.priority == .critical, "Calls should be critical priority")

            plugin.handle(banners: [callBanner, RawBanner(texts: ["Slack", "Alice", "hi"])])
            check(coordinator.persistentActivity?.priority == .critical, "A message must not replace an active call")

            plugin.acceptCurrent()
            check(accepted, "Accept should press the banner's Accept button")
            check(coordinator.persistentActivity == nil, "Activity should clear after accepting")

            plugin.slackEnabled = false
            plugin.handle(banners: [RawBanner(texts: ["Slack", "Zed", "ignored"])])
            check(coordinator.persistentActivity == nil, "Disabled app should not publish")

            plugin.slackEnabled = true

            plugin.outlookEnabled = false
            plugin.handle(banners: [RawBanner(texts: ["Microsoft Outlook", "Subject", "Dana", "Preview"])])
            check(coordinator.persistentActivity == nil, "Disabled Outlook should not publish")
            plugin.outlookEnabled = true
            plugin.handle(banners: [])
            plugin.handle(banners: [RawBanner(texts: ["Microsoft Outlook", "Subject", "Dana", "Preview"])])
            check(coordinator.persistentActivity?.priority == .high, "Outlook email should publish with high priority")
            plugin.dismissCurrent()

            plugin.stop()
            print("  [PASS] testNotificationBridgePlugin")
        }

        print("==> Test Results: \(passed) checks passed, \(failed) failed.")
        if failed > 0 {
            Foundation.exit(1)
        }
    }
}
