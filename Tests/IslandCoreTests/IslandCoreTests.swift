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
            UserDefaults.standard.removeObject(forKey: "island.airdrop.autoExpandIncomingAlerts")
            defer {
                UserDefaults.standard.removeObject(forKey: "island.airdrop.autoExpandIncomingAlerts")
            }

            let coordinator = NotchStateCoordinator(hoverExpandDelayMs: 50)
            let airDropPlugin = AirDropPlugin()
            airDropPlugin.isEnabled = true
            airDropPlugin.autoExpandIncomingAlerts = true
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

            // Test 6-digit AirDrop verification code banner parser with live AX tree string format
            let parsedCode = AirDropReceiverService.parseAirDropVerificationCodeStrings([
                "AirDrop Code for “Alex Rivera”, Ask Alex to enter “350896” on their device.",
                "AirDrop Code for “Alex Rivera”",
                "Ask Alex to enter “350896” on their device."
            ])
            check(parsedCode != nil, "6-digit AirDrop code banner should be recognized")
            check(parsedCode?.sender == "Alex Rivera", "Should extract sender 'Alex Rivera' from AirDrop Code header")
            check(parsedCode?.code == "350896", "Should extract 6-digit code '350896'")
            check(parsedCode?.instruction == "Ask Alex to enter “350896” on their device.", "Should preserve instruction subtitle")

            // Ensure regular file request banners are not mistaken for verification code banners
            let nonCode = AirDropReceiverService.parseAirDropVerificationCodeStrings([
                "AirDrop",
                "cashyos-desktop would like to share a photo",
                "Decline",
                "Accept"
            ])
            check(nonCode == nil, "Standard incoming file share banner should not match verification code parser")

            // Simulate incoming 6-digit verification code with autoExpandIncomingAlerts = true
            airDropPlugin.simulateIncomingCodeRequest()
            check(airDropPlugin.receiverService.activeSession?.phase == .awaitingVerificationCode, "Session phase should be .awaitingVerificationCode")
            check(airDropPlugin.receiverService.activeSession?.payloadKind == .verificationCode(code: "350896"), "Payload kind should carry the 6-digit code")
            check(coordinator.posture == .expandedCard, "Incoming 6-digit code should expand into .expandedCard when autoExpandIncomingAlerts is true")
            check(coordinator.persistentActivity?.wingSizes.rightWidth == 78, "Compact wing width for 6-digit code should be 78pt")

            // Toggling autoExpandIncomingAlerts = false should start/collapse incoming alerts to .compactWings
            airDropPlugin.autoExpandIncomingAlerts = false
            check(coordinator.posture == .compactWings, "Disabling autoExpandIncomingAlerts should present incoming code in .compactWings")

            airDropPlugin.declineTransfer()
            check(coordinator.posture == .resting, "Dismissing verification code session should return Island to .resting")

            // Simulate incoming code when autoExpandIncomingAlerts is false from the start
            airDropPlugin.simulateIncomingCodeRequest()
            check(coordinator.posture == .compactWings, "Incoming code should start in .compactWings when autoExpandIncomingAlerts is false")
            airDropPlugin.declineTransfer()
            airDropPlugin.autoExpandIncomingAlerts = true

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

            // Test Outgoing AirDrop Drag-to-Send & In-Island Receiver Picker lifecycle
            let noHoverDelayCoordinator = NotchStateCoordinator(hoverExpandDelayMs: 0)
            airDropPlugin.start(coordinator: noHoverDelayCoordinator)

            // 1. Dragging files near the notch expands into .dropzoneHover (.expandedCard)
            airDropPlugin.handleFileDragHoverChanged(true)
            check(airDropPlugin.senderService.activeSession?.phase == .dropzoneHover, "Dragging files near notch should enter .dropzoneHover phase")
            check(noHoverDelayCoordinator.posture == .expandedCard, "Dropzone hover should expand Island into .expandedCard")

            // Dragging away without dropping returns to .resting
            airDropPlugin.handleFileDragHoverChanged(false)
            check(airDropPlugin.senderService.activeSession == nil, "Dragging away without dropping should clear dropzone session")
            check(noHoverDelayCoordinator.posture == .resting, "Dragging away without dropping should collapse Island back to .resting")

            // 2. Dropping files stages them in .selectingRecipient and opens .expandedCard
            airDropPlugin.simulateOutgoingDrop()
            check(airDropPlugin.senderService.activeSession?.phase == .selectingRecipient, "Dropping files should transition to .selectingRecipient")
            check(airDropPlugin.senderService.activeSession?.fileURLs.count == 2, "Simulated drop should stage 2 files")
            check(airDropPlugin.senderService.activeSession?.compactWingBadgeText == "2 Files", "Compact badge should read '2 Files'")
            check(noHoverDelayCoordinator.posture == .expandedCard, "Dropping files should keep Island open in .expandedCard to pick a receiver")

            // 3. Moving cursor away minimizes into .compactWings while keeping staged files & session alive
            noHoverDelayCoordinator.handleHoverExited()
            check(noHoverDelayCoordinator.posture == .compactWings, "Moving cursor away from staged outgoing AirDrop should minimize into .compactWings")
            check(airDropPlugin.senderService.activeSession?.phase == .selectingRecipient, "Staged outgoing session must stay alive in .selectingRecipient when minimized")

            // 4. Clicking/hovering back onto the Island re-expands into .expandedCard
            noHoverDelayCoordinator.handleNotchClicked()
            check(noHoverDelayCoordinator.posture == .expandedCard, "Returning to minimized outgoing AirDrop should re-expand into .expandedCard")

            // 5. Clicking a recipient starts sending
            if let recipient = airDropPlugin.senderService.activeSession?.recipients.first {
                airDropPlugin.sendOutgoingToRecipient(recipient)
                check(airDropPlugin.senderService.activeSession?.phase == .sending(recipientName: recipient.displayName), "Clicking a recipient should transition outgoing session to .sending")
            } else {
                check(false, "Simulated outgoing drop should provide at least one recipient")
            }

            // 6. Cancelling outgoing session clears state and returns Island to .resting
            airDropPlugin.cancelOutgoingSession()
            check(airDropPlugin.senderService.activeSession == nil, "Cancelling outgoing session should clear activeSession")
            check(noHoverDelayCoordinator.posture == .resting, "Cancelling outgoing session should return Island to .resting")

            airDropPlugin.stop()
            print("  [PASS] testIncomingAndOutgoingAirDropStateMachine")
        }

        // WindowController drag proximity & pasteboard isolation test
        do {
            let coordinator = NotchStateCoordinator()
            let geometryMonitor = ScreenGeometryMonitor()
            let windowController = NotchWindowController(
                coordinator: coordinator,
                geometryMonitor: geometryMonitor,
                defaultExpandedContent: { AnyView(EmptyView()) }
            )
            var dragHoverState: Bool?
            windowController.onFileDragHoverChanged = { active in
                dragHoverState = active
            }

            // Stale items on NSPasteboard(name: .drag) from prior system sessions must be ignored on startup
            check(dragHoverState == nil, "Initial drag hover state must be idle (no false dropzone trigger)")

            windowController.close()
            print("  [PASS] testWindowControllerDragSessionIsolation")
        }

        // Notification parsers
        do {
            check(BannerTextCleaner.isTimeMarker("now"), "Time marker 'now'")
            check(BannerTextCleaner.isTimeMarker("nu"), "Time marker 'nu'")
            check(BannerTextCleaner.isTimeMarker("yesterday"), "Time marker 'yesterday'")
            check(BannerTextCleaner.isTimeMarker("gisteren"), "Time marker 'gisteren'")
            check(BannerTextCleaner.isTimeMarker("10m ago"), "Relative time marker '10m ago'")
            check(BannerTextCleaner.isTimeMarker("10m"), "Relative time marker '10m'")
            check(BannerTextCleaner.isTimeMarker("19m ago"), "Relative time marker '19m ago'")
            check(BannerTextCleaner.isTimeMarker("2h ago"), "Relative time marker '2h ago'")
            check(BannerTextCleaner.isTimeMarker("vor 10 Min"), "Relative time marker 'vor 10 Min'")
            check(BannerTextCleaner.isTimeMarker("il y a 5 min"), "Relative time marker 'il y a 5 min'")
            check(!BannerTextCleaner.isTimeMarker("Bob Niroomand"), "Normal name is not time marker")
            check(!BannerTextCleaner.isTimeMarker("team-stock-allocation-engineering"), "Channel is not time marker")

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
            check(email?.title == "Q4 notes", "Email title should be the subject")
            check(email?.body == "See attached", "Email body should be the preview without duplicating the subject")
            let noPreview = parsers.parse(RawBanner(texts: ["Microsoft Outlook, Lunch?, Dana Lee", "Lunch?", "Dana Lee"]))
            check(noPreview?.title == "Lunch?", "Email without preview should carry subject in title")
            check(noPreview?.body == "", "Email without preview should have empty body")
            check(parsers.parse(RawBanner(texts: ["Microsoft Outlook", "Weekly sync", "Starts in 5 minutes"])) == nil, "Outlook calendar reminders are ignored")

            let realOutlook = parsers.parse(RawBanner(texts: [
                "Microsoft Outlook, Re: Test hello world, Erencan Kanmaz, CAUTION: This email originated from outside. Hillo",
                "Re: Test hello world",
                "Erencan Kanmaz",
                "CAUTION: This email originated from outside. Hillo"
            ]))
            check(realOutlook?.kind == .email, "Captured real Outlook banner should parse as an email")
            check(realOutlook?.sender == "Erencan Kanmaz", "Captured Outlook banner sender is the subtitle")
            check(realOutlook?.title == "Re: Test hello world", "Captured Outlook banner title is the subject")
            check(realOutlook?.subtext == "Re: Test hello world", "Captured Outlook banner subtext is the subject")
            check(realOutlook?.body == "CAUTION: This email originated from outside. Hillo", "Captured Outlook banner body is the preview text")

            let replyOutlook = parsers.parse(RawBanner(texts: [
                "Microsoft Outlook, Re: Testing 123, Alex Rivera, Sounds good On Sat, 7 Nov 2026, 15:40 Alex Rivera, <alex@example.com> wrote: How is the rollout going?, stacked",
                "Re: Testing 123",
                "Alex Rivera",
                "Sounds good On Sat, 7 Nov 2026, 15:40 Alex Rivera, <alex@example.com> wrote: How is the rollout going?"
            ]))
            check(replyOutlook?.title == "Re: Testing 123", "Reply Outlook email subject parsed")
            check(replyOutlook?.sender == "Alex Rivera", "Reply Outlook email sender parsed")
            check(replyOutlook?.body == "Sounds good On Sat, 7 Nov 2026, 15:40 Alex Rivera, <alex@example.com> wrote: How is the rollout going?", "Reply Outlook email preserves full body even when sender name is quoted")

            let whatsAppGroup = parsers.parse(RawBanner(texts: [
                "\u{200E}WhatsApp, Sam Carter, Weekend Plans, See you all at 7!",
                "Sam Carter",
                "Weekend Plans",
                "See you all at 7!"
            ]))
            check(whatsAppGroup?.appName == "WhatsApp", "WhatsApp parser recognizes U+200E prefixed banner")
            check(whatsAppGroup?.sender == "Sam Carter", "WhatsApp group sender extracted")
            check(whatsAppGroup?.channel == "Weekend Plans", "WhatsApp group name extracted as channel")
            check(whatsAppGroup?.headline == "Sam Carter · Weekend Plans", "WhatsApp group headline combines sender and group")
            check(whatsAppGroup?.body == "See you all at 7!", "WhatsApp group message body extracted")

            let whatsAppDirect = parsers.parse(RawBanner(texts: [
                "WhatsApp, Sam Carter, Hey are you around?",
                "Sam Carter",
                "Hey are you around?"
            ]))
            check(whatsAppDirect?.sender == "Sam Carter", "WhatsApp direct sender extracted")
            check(whatsAppDirect?.channel == nil, "WhatsApp direct message has nil channel")
            check(whatsAppDirect?.body == "Hey are you around?", "WhatsApp direct message body extracted")

            let whatsAppCall = parsers.parse(RawBanner(texts: [
                "WhatsApp",
                "Sam Carter",
                "Incoming voice call"
            ]))
            check(whatsAppCall?.kind == .incomingCall && whatsAppCall?.sender == "Sam Carter", "WhatsApp voice call recognized as incomingCall")

            let modernSlack = parsers.parse(RawBanner(texts: [
                "Slack, acme, acme-team-25, Alex Rivera: Hey team the latest update is ready",
                "acme",
                "acme-team-25",
                "Alex Rivera: Hey team the latest update is ready"
            ]))
            check(modernSlack?.appName == "Slack", "Modern Slack banner recognized")
            check(modernSlack?.sender == "Alex Rivera", "Sender extracted from message prefix")
            check(modernSlack?.channel == "#acme-team-25", "Channel formatted with hashtag")
            check(modernSlack?.body == "Hey team the latest update is ready", "Message body stripped of sender prefix")
            check(modernSlack?.headline == "Alex Rivera · #acme-team-25", "Headline contains sender and channel")
            check(modernSlack?.subtext == "Hey team the latest update is ready", "Subtext contains message text")

            let slackGroup = parsers.parse(RawBanner(texts: [
                "Slack, acme, Alex Rivera, Jordan Lee, Alex Rivera: Looking into it now",
                "acme",
                "Alex Rivera, Jordan Lee",
                "Alex Rivera: Looking into it now"
            ]))
            check(slackGroup?.sender == "Alex Rivera", "Group DM sender extracted")
            check(slackGroup?.channel == "Alex Rivera, Jordan Lee", "Group DM channel preserved")
            check(slackGroup?.body == "Looking into it now", "Group DM body extracted")

            let slack1on1 = parsers.parse(RawBanner(texts: [
                "Slack, acme, Alex Rivera, Alex Rivera: Looking into it now",
                "acme",
                "Alex Rivera",
                "Alex Rivera: Looking into it now"
            ]))
            check(slack1on1?.sender == "Alex Rivera", "1-on-1 DM sender extracted")
            check(slack1on1?.channel == nil, "1-on-1 DM has no channel")
            check(slack1on1?.headline == "Alex Rivera", "Headline is sender only")
            check(slack1on1?.subtext == "Looking into it now", "Subtext is message")

            let slackDirectNoColon = parsers.parse(RawBanner(texts: [
                "Slack, bol, Guus Eijsvogels, Hier lijkt wat mis te gaan",
                "bol",
                "Guus Eijsvogels",
                "Hier lijkt wat mis te gaan"
            ]))
            check(slackDirectNoColon?.sender == "Guus Eijsvogels", "Direct DM sender extracted without colon")
            check(slackDirectNoColon?.channel == nil, "Direct DM has no channel")
            check(slackDirectNoColon?.headline == "Guus Eijsvogels", "Direct DM headline is sender only")
            check(slackDirectNoColon?.subtext == "Hier lijkt wat mis te gaan", "Direct DM subtext is message body")

            // Test Tray & Relative Timestamp Detection
            check(BannerTextCleaner.isRelativeTimeMarker("1m ago"), "Relative '1m ago' recognized")
            check(BannerTextCleaner.isRelativeTimeMarker("10m ago"), "Relative '10m ago' recognized")
            check(BannerTextCleaner.isRelativeTimeMarker("10 min. geleden"), "Dutch relative time recognized")
            check(BannerTextCleaner.isRelativeTimeMarker("gisteren"), "Dutch yesterday recognized")
            check(BannerTextCleaner.isRelativeTimeMarker("yesterday"), "English yesterday recognized")
            check(!BannerTextCleaner.isRelativeTimeMarker("now"), "'now' is not relative past time")
            check(!BannerTextCleaner.isRelativeTimeMarker("nu"), "'nu' is not relative past time")

            check(BannerTextCleaner.isClockTimeMarker("14:32"), "Clock time 14:32 recognized")
            check(BannerTextCleaner.isClockTimeMarker("2:45 PM"), "Clock time 2:45 PM recognized")
            check(!BannerTextCleaner.isClockTimeMarker("Meeting at 14:32"), "Inline clock time not mistaken for label")

            let trayHoveredSlack = RawBanner(
                texts: [
                    "Slack, bol, Guus Eijsvogels, Lydia van Dam, Guus Eijsvogels: Voelt sketchy op vrijdagmiddag",
                    "bol",
                    "Guus Eijsvogels, Lydia van Dam",
                    "Guus Eijsvogels: Voelt sketchy op vrijdagmiddag",
                    "Show Details", "Reply", "Close"
                ],
                buttons: [BannerButton(title: "Show Details", press: { true }), BannerButton(title: "Close", press: { true })]
            )
            check(BannerTextCleaner.isTrayItem(trayHoveredSlack), "Hovered tray Slack notification recognized as tray item")

            let trayHoveredOutlook = RawBanner(
                texts: [
                    "Microsoft Outlook, Re: Test hello world, Erencan Kanmaz, Content here",
                    "Re: Test hello world",
                    "Erencan Kanmaz",
                    "Content here",
                    "Show Details", "Delete", "Close"
                ],
                buttons: [BannerButton(title: "Show Details", press: { true }), BannerButton(title: "Delete", press: { true })]
            )
            check(BannerTextCleaner.isTrayItem(trayHoveredOutlook), "Hovered tray Outlook notification recognized as tray item")

            let liveSlackWithDetailsWord = RawBanner(
                texts: [
                    "Slack, bol, Guus Eijsvogels, Here are the project details",
                    "bol",
                    "Guus Eijsvogels",
                    "Here are the project details"
                ]
            )
            check(!BannerTextCleaner.isTrayItem(liveSlackWithDetailsWord), "Live message mentioning details word is not classified as tray item")
            check(parsers.parse(liveSlackWithDetailsWord)?.subtext == "Here are the project details", "Live message body parsed cleanly")

            check(parsers.parse(RawBanner(texts: ["Mail", "Eve", "Hello"])) == nil, "Unknown apps are not handled by app parsers")
            check(parsers.parseGeneric(RawBanner(texts: ["Mail", "Eve", "Hello"]))?.appName == "Mail", "Generic parser should use first text as app name")

            // Inline reply parsing & chrome filtering
            let expandedWhatsAppReply = RawBanner(
                texts: [
                    "WhatsApp, ~ Alexandre, Boulderen , 18:30?",
                    "~ Alexandre",
                    "Boulderen ",
                    "18:30?",
                    "More Actions…",
                    "Hide Details",
                    "Send"
                ],
                canReply: true
            )
            let parsedWhatsApp = parsers.parse(expandedWhatsAppReply)
            check(parsedWhatsApp?.canReply == true, "Parsed WhatsApp notification inherits canReply")
            check(parsedWhatsApp?.sender == "~ Alexandre", "Expanded WhatsApp sender parsed cleanly without chrome")
            check(parsedWhatsApp?.body == "18:30?", "Expanded WhatsApp body parsed cleanly without Send or Hide Details chrome")

            let outlookWithDetails = RawBanner(
                texts: [
                    "Microsoft Outlook, Team Standup, Alex, Meeting in 10m",
                    "Team Standup",
                    "Alex",
                    "Meeting in 10m"
                ],
                canReply: false
            )
            let parsedOutlook = parsers.parse(outlookWithDetails)
            check(parsedOutlook?.canReply == false, "Outlook email notification is never replyable")

            let expandedSlackReply = RawBanner(
                texts: [
                    "Slack, bol, Lydia van Dam, Nice, ik ga er morgen even doorheen.",
                    "bol",
                    "Lydia van Dam",
                    "Nice, ik ga er morgen even doorheen.",
                    "More Actions…",
                    "Hide Details",
                    "Reply"
                ],
                buttons: [
                    BannerButton(title: "More Actions…", press: { true }),
                    BannerButton(title: "Hide Details", press: { true }),
                    BannerButton(title: "Reply", press: { true })
                ],
                canReply: true
            )
            let parsedExpandedSlack = parsers.parse(expandedSlackReply)
            check(parsedExpandedSlack?.canReply == true, "Expanded Slack notification preserves canReply")
            check(parsedExpandedSlack?.sender == "Lydia van Dam", "Expanded Slack sender parsed cleanly without chrome")
            check(parsedExpandedSlack?.body == "Nice, ik ga er morgen even doorheen.", "Expanded Slack body strips More Actions, Hide Details, and Reply chrome")

            let localizedExpandedSlack = RawBanner(
                texts: ["Slack", "Alex", "Hallo!", "Weitere Aktionen…", "Details ausblenden", "Antworten"],
                canReply: true
            )
            let parsedLocalizedSlack = parsers.parse(localizedExpandedSlack)
            check(parsedLocalizedSlack?.body == "Hallo!", "Expanded Slack body strips localized action chrome")

            // Thread keys for conversation grouping
            let slackDMThread = parsers.parse(RawBanner(texts: ["Slack, bol, Lydia van Dam, Hey", "bol", "Lydia van Dam", "Hey"]))
            let slackChannelThread = parsers.parse(RawBanner(texts: ["Slack, bol, engineering, Bob: Build passed", "bol", "engineering", "Bob: Build passed"]))
            let whatsAppDMThread = parsers.parse(RawBanner(texts: ["WhatsApp", "Alex", "Ping"]))
            let whatsAppGroupNotif = parsers.parse(RawBanner(texts: ["WhatsApp", "Sam", "Weekend Plans", "Hi!"]))
            let whatsAppCallNotif = parsers.parse(RawBanner(texts: ["WhatsApp", "Sam", "Incoming voice call"]))
            check(slackDMThread?.threadKey == "slack|dm|lydia van dam", "Slack DM threadKey groups by sender")
            check(slackChannelThread?.threadKey == "slack|channel|#engineering", "Slack channel threadKey groups by channel")
            check(whatsAppDMThread?.threadKey == "whatsapp|dm|alex", "WhatsApp DM threadKey groups by sender")
            check(whatsAppGroupNotif?.threadKey == "whatsapp|channel|weekend plans", "WhatsApp group threadKey groups by group channel")
            check(whatsAppCallNotif?.threadKey == nil, "Incoming call has nil threadKey")
            check(parsedOutlook?.threadKey == nil, "Outlook email has nil threadKey")

            print("  [PASS] testNotificationParsers")
        }

        // Notification bridge plugin
        do {
            let notificationDefaultsKeys = [
                "island.plugin.com.island.plugin.notifications.enabled",
                "island.notifications.slack",
                "island.notifications.teams",
                "island.notifications.outlook",
                "island.notifications.whatsapp",
                "island.notifications.hideBanner.slack",
                "island.notifications.hideBanner.teams",
                "island.notifications.hideBanner.outlook",
                "island.notifications.hideBanner.whatsapp",
                "island.notifications.otherApps",
                "island.notifications.messageDuration",
                "island.notifications.maxWingWidth",
                "island.notifications.keepUntilDismissed"
            ]
            for key in notificationDefaultsKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in notificationDefaultsKeys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }

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

            var hideCalls = 0
            plugin.hideOutlookBanner = true
            plugin.handle(banners: [RawBanner(texts: ["Microsoft Outlook", "S", "Dana", "P"], hideBanner: { hideCalls += 1 })])
            check(hideCalls == 1, "Banner should be hidden once when hide option is enabled")
            plugin.hideOutlookBanner = false
            plugin.handle(banners: [])
            plugin.handle(banners: [RawBanner(texts: ["Microsoft Outlook", "S", "Dana", "P"], hideBanner: { hideCalls += 1 })])
            check(hideCalls == 1, "Banner must not be hidden when hide option is disabled")
            plugin.dismissCurrent()
            plugin.handle(banners: [])

            plugin.hideOutlookBanner = true
            plugin.handle(banners: [RawBanner(
                texts: ["Microsoft Outlook", "S", "Dana", "P"],
                buttons: [BannerButton(title: "Close", press: { true })],
                hideBanner: { hideCalls += 1 }
            )])
            check(hideCalls == 1, "Re-exposed identical notification must not be dismissed or presented again")
            check(coordinator.persistentActivity == nil, "Re-exposed identical notification must not publish")
            plugin.hideOutlookBanner = false

            plugin.outlookEnabled = false
            plugin.handle(banners: [RawBanner(texts: ["Microsoft Outlook", "Subject", "Dana", "Preview"])])
            check(coordinator.persistentActivity == nil, "Disabled Outlook should not publish")
            plugin.outlookEnabled = true
            plugin.handle(banners: [])
            plugin.handle(banners: [RawBanner(texts: ["Microsoft Outlook", "Subject", "Dana", "Preview"])])
            check(coordinator.persistentActivity?.priority == .high, "Outlook email should publish with high priority")
            plugin.dismissCurrent()

            let historicalSlack = RawBanner(texts: [
                "Slack, bol, Guus Eijsvogels, Lydia van Dam, Guus Eijsvogels: Voelt sketchy op vrijdagmiddag",
                "bol",
                "Guus Eijsvogels, Lydia van Dam",
                "Guus Eijsvogels: Voelt sketchy op vrijdagmiddag",
                "4m ago"
            ], hideBanner: { hideCalls += 1 })
            plugin.hideSlackBanner = true
            plugin.handle(banners: [historicalSlack])
            check(coordinator.persistentActivity == nil, "Historical notification with '4m ago' should be ignored")
            check(hideCalls == 1, "Historical notification should not trigger hideBanner")

            let hoveredSlack = RawBanner(texts: [
                "Slack, bol, Guus Eijsvogels, Lydia van Dam, Guus Eijsvogels: Voelt sketchy op vrijdagmiddag",
                "bol",
                "Guus Eijsvogels, Lydia van Dam",
                "Guus Eijsvogels: Voelt sketchy op vrijdagmiddag",
                "Show Details", "Reply", "Close"
            ], buttons: [BannerButton(title: "Show Details", press: { true }), BannerButton(title: "Close", press: { true })],
            hideBanner: { hideCalls += 1 })
            plugin.handle(banners: [hoveredSlack])
            check(coordinator.persistentActivity == nil, "Hovered tray card with 'Show Details' should be ignored")
            check(hideCalls == 1, "Hovered tray card should not trigger hideBanner")
            plugin.hideSlackBanner = false

            let emailNotif = IslandNotification(appName: "Microsoft Outlook", kind: .email, sender: "Sarah Connor", title: "Q4 planning", channel: nil, body: "See attached")
            let computedWidth = NotificationBridgePlugin.messageWingWidth(for: emailNotif, maxAllowedWidth: 185)
            check(computedWidth >= 70 && computedWidth <= 185, "Message wing width should fit content and clamp to max")

            let cappedWidth = NotificationBridgePlugin.messageWingWidth(for: emailNotif, maxAllowedWidth: 100)
            check(cappedWidth <= 100, "Message wing width respects custom max limit")

            plugin.maxWingWidth = 210
            check(plugin.maxWingWidth == 210, "Max wing width update")

            check(plugin.messageDuration >= 2.0 && plugin.messageDuration <= 10.0, "Message duration is within valid bounds")
            plugin.messageDuration = 6.5
            check(UserDefaults.standard.double(forKey: "island.notifications.messageDuration") == 6.5, "Message duration persists to UserDefaults")

            plugin.triggerWidthPreview(isEditing: true)
            check(plugin.isCalibratingWidth == true, "Trigger width preview should enter calibrating state")
            check(coordinator.persistentActivity != nil, "Width preview should publish activity")
            check(coordinator.persistentActivity?.wingSizes.rightWidth == 210, "Right wing width should match calibrating width")
            plugin.triggerWidthPreview(isEditing: false)
            check(plugin.isCalibratingWidth == false, "Stopping width preview resets calibrating state")
            plugin.dismissCurrent()

            // Test inline reply lifecycle
            var beginReplyCalled = false
            var replySentText: String?
            let replyableBanner = RawBanner(
                texts: ["Slack", "Alex", "Can you review this?"],
                canReply: true,
                beginReply: {
                    beginReplyCalled = true
                    return true
                },
                sendReply: { text in
                    replySentText = text
                    return true
                }
            )
            plugin.handle(banners: [replyableBanner])
            check(coordinator.persistentActivity != nil, "Replyable banner should publish persistent activity")

            // Begin reply
            plugin.beginReply()
            check(plugin.isReplying == true, "beginReply sets isReplying to true")
            check(coordinator.isTextInputActive == true, "beginReply activates isTextInputActive on coordinator")
            check(beginReplyCalled == true, "beginReply invokes banner.beginReply closure")

            // Hover exit should NOT collapse while isTextInputActive is true
            coordinator.handleHoverExited()
            check(coordinator.posture == .expandedCard, "Expanded card remains open when hover exits during text input")

            // Cancel reply
            plugin.cancelReply()
            check(plugin.isReplying == false, "cancelReply sets isReplying to false")
            check(coordinator.isTextInputActive == false, "cancelReply deactivates isTextInputActive on coordinator")

            // Begin reply again and submit
            plugin.beginReply()
            plugin.replyDraft = "  LGTM!  "

            // Mutated expanded banner arriving while replying must keep draft, hide banner if configured, and update banner reference
            plugin.hideSlackBanner = true
            var mutatedHideCalls = 0
            var mutatedReplySentText: String?
            let mutatedExpandedBanner = RawBanner(
                texts: ["Slack", "Alex", "Can you review this?", "Hide Details", "Reply"],
                canReply: true,
                hideBanner: { mutatedHideCalls += 1 },
                sendReply: { text in
                    mutatedReplySentText = text
                    return true
                }
            )
            plugin.handle(banners: [mutatedExpandedBanner])
            check(plugin.isReplying == true, "Mutated banner for same notification must not reset isReplying")
            check(plugin.replyDraft == "  LGTM!  ", "Mutated banner for same notification must preserve replyDraft")
            check(mutatedHideCalls == 1, "Mutated banner for hidden app is hidden while replying")
            plugin.hideSlackBanner = false

            plugin.submitReply()
            check(mutatedReplySentText == "LGTM!", "submitReply trims and delivers reply text to latest banner.sendReply")
            check(replySentText == nil, "submitReply uses updated banner reference after in-place expansion")
            check(plugin.isReplying == false, "submitReply resets isReplying to false")
            check(coordinator.isTextInputActive == false, "submitReply resets isTextInputActive to false")
            check(coordinator.persistentActivity == nil, "submitReply dismisses current active notification")

            // Test keepUntilDismissed history & swipe navigation
            check(plugin.keepUntilDismissed == false, "keepUntilDismissed defaults to false")
            plugin.keepUntilDismissed = true
            check(UserDefaults.standard.bool(forKey: "island.notifications.keepUntilDismissed") == true, "keepUntilDismissed persists to UserDefaults")

            var firstBannerAlive = true
            let olderBanner = RawBanner(
                texts: ["Slack", "Lydia", "Nice, ik ga er morgen even doorheen."],
                canReply: true,
                isBannerAlive: { firstBannerAlive }
            )
            let newerBanner = RawBanner(
                texts: ["WhatsApp", "Sam", "Are we still on for 7?"],
                canReply: true,
                isBannerAlive: { true }
            )
            plugin.handle(banners: [olderBanner])
            plugin.handle(banners: [newerBanner])
            check(plugin.history.count == 2, "keepUntilDismissed retains both incoming notifications in history")
            check(coordinator.keptNotificationCount == 2, "Coordinator reflects keptNotificationCount == 2")
            check(plugin.history.first?.notification.appName == "WhatsApp", "Newest notification is at index 0")

            // Simulate toast expiry (banner gone from screen)
            firstBannerAlive = false
            let olderEntry = plugin.history[1]
            check(plugin.canReply(to: olderEntry.notification, entryID: olderEntry.id) == false, "Expired banner cannot inline-reply")
            let newerEntry = plugin.history[0]
            check(plugin.canReply(to: newerEntry.notification, entryID: newerEntry.id) == true, "Live banner can still inline-reply")

            // Swipe down while viewing expanded card opens history
            coordinator.clearPersistentActivity(pluginID: plugin.id, forceCollapseHover: false)
            coordinator.handleNotchClicked()
            coordinator.handleExpandedSwipe(.down)
            check(plugin.isBrowsingHistory == true, "Swiping down in expanded card opens kept notification history")
            check(plugin.selectedHistoryIndex == 0, "History opens at newest notification (index 0)")

            // Swiping left cycles to older notification; swiping down does not cycle further
            coordinator.handleExpandedSwipe(.down)
            check(plugin.selectedHistoryIndex == 0, "Swiping down while browsing history does not advance")
            coordinator.handleExpandedSwipe(.left)
            check(plugin.selectedHistoryIndex == 1, "Swiping left moves to older notification (index 1)")

            // Reply lock blocks swipe navigation
            plugin.beginReply()
            coordinator.handleExpandedSwipe(.right)
            check(plugin.selectedHistoryIndex == 1, "Swiping is locked while typing a reply")
            plugin.cancelReply()

            // Swiping right returns to newer notification and stays at index 0
            coordinator.handleExpandedSwipe(.right)
            check(plugin.selectedHistoryIndex == 0, "Swiping right returns to newer notification (index 0)")
            coordinator.handleExpandedSwipe(.right)
            check(plugin.isBrowsingHistory == true && plugin.selectedHistoryIndex == 0, "Swiping right at index 0 stays in history")

            // Swiping up from any index immediately closes history back to default card
            coordinator.handleExpandedSwipe(.left)
            check(plugin.selectedHistoryIndex == 1, "Moved back to index 1")
            coordinator.handleExpandedSwipe(.up)
            check(plugin.isBrowsingHistory == false, "Swiping up from index 1 immediately closes history drawer")
            check(plugin.history.count == 2, "Closing history drawer preserves kept notifications")

            // Moving cursor away (hover exit) closes history drawer and collapses posture (never trapped open)
            coordinator.handleExpandedSwipe(.down)
            check(plugin.isBrowsingHistory == true && coordinator.posture == .expandedCard, "History opened in expanded posture")
            coordinator.handleHoverExited()
            check(plugin.isBrowsingHistory == false, "Hover exit closes history drawer")
            check(coordinator.posture == .resting, "Hover exit collapses expanded card to resting")
            check(plugin.history.count == 2, "Hover exit preserves kept notifications")
            coordinator.handleNotchClicked()

            // Dismissing while browsing removes only the dismissed notification and advances
            plugin.openHistory(at: 0)
            plugin.dismissCurrent()
            check(plugin.history.count == 1, "Dismissing removes only the dismissed notification")
            check(plugin.history[0].notification.sender == "Lydia", "Remaining notification stays in history")
            check(plugin.isBrowsingHistory == true, "Dismissing advances to remaining kept notification")

            plugin.clearAllHistory()
            check(plugin.history.isEmpty, "clearAllHistory empties kept notifications")
            check(coordinator.keptNotificationCount == 0, "Coordinator badge count resets to 0")

            // Test thread grouping across consecutive DMs and group messages
            var waMsg1Sent: String?
            var waMsg2Sent: String?
            let waDM1 = RawBanner(
                texts: ["WhatsApp", "Alexandre", "Boulderen?"],
                canReply: true,
                isBannerAlive: { true },
                sendReply: { text in waMsg1Sent = text; return true }
            )
            let slackGroup1 = RawBanner(
                texts: ["Slack, bol, dev, Lydia: Checking PR", "bol", "dev", "Lydia: Checking PR"],
                canReply: true,
                isBannerAlive: { true }
            )
            let waDM2 = RawBanner(
                texts: ["WhatsApp", "Alexandre", "18:30?"],
                canReply: true,
                isBannerAlive: { true },
                sendReply: { text in waMsg2Sent = text; return true }
            )
            let slackGroup2 = RawBanner(
                texts: ["Slack, bol, dev, Bob: Looks good!", "bol", "dev", "Bob: Looks good!"],
                canReply: true,
                isBannerAlive: { true }
            )

            plugin.handle(banners: [waDM1])
            plugin.handle(banners: [slackGroup1])
            check(plugin.history.count == 2, "Two distinct conversations create 2 thread entries")
            check(plugin.history[0].notification.channel == "#dev", "Newest conversation is Slack #dev at index 0")

            // A second DM from Alexandre merges into the existing WhatsApp DM thread and moves it to top
            plugin.handle(banners: [waDM2])
            check(plugin.history.count == 2, "Second WhatsApp DM from same sender merges into existing thread")
            check(plugin.history[0].notification.sender == "Alexandre", "Updated WhatsApp DM thread moves to index 0")
            check(plugin.history[0].messages.map(\.body) == ["Boulderen?", "18:30?"], "Merged DM thread preserves chronological message bodies")

            // A second message from a different sender in Slack #dev merges into the #dev thread
            plugin.handle(banners: [slackGroup2])
            check(plugin.history.count == 2, "Different sender in same Slack channel merges into #dev thread")
            check(plugin.history[0].messages.map { "\($0.sender): \($0.body)" } == [
                "Lydia: Checking PR",
                "Bob: Looks good!"
            ], "Merged channel thread preserves sender + body per message")

            // Preserving active reply draft when a third message arrives in the same thread
            plugin.beginReply()
            plugin.replyDraft = "Omw!"
            var slackMsg3Sent: String?
            let slackGroup3 = RawBanner(
                texts: ["Slack, bol, dev, Lydia: Merging now", "bol", "dev", "Lydia: Merging now"],
                canReply: true,
                isBannerAlive: { true },
                sendReply: { text in slackMsg3Sent = text; return true }
            )
            plugin.handle(banners: [slackGroup3])
            check(plugin.isReplying == true, "Incoming message in active reply thread preserves isReplying")
            check(plugin.replyDraft == "Omw!", "Incoming message in active reply thread preserves replyDraft")
            check(plugin.history[0].messages.count == 3, "Third message appended to thread while replying")

            plugin.submitReply()
            check(slackMsg3Sent == "Omw!", "submitReply uses latest live banner in the grouped thread")
            check(waMsg1Sent == nil && waMsg2Sent == nil, "Other threads' banners were not invoked")

            // Cancel reply after preserveReply still allows hover exit to collapse posture
            let slackGroup4 = RawBanner(
                texts: ["Slack, bol, dev, Bob: Still checking?", "bol", "dev", "Bob: Still checking?"],
                canReply: true,
                isBannerAlive: { true }
            )
            let slackGroup5 = RawBanner(
                texts: ["Slack, bol, dev, Lydia: Yes, almost done", "bol", "dev", "Lydia: Yes, almost done"],
                canReply: true,
                isBannerAlive: { true }
            )
            plugin.handle(banners: [slackGroup4])
            plugin.beginReply()
            plugin.handle(banners: [slackGroup5])
            plugin.cancelReply()
            coordinator.handleHoverExited()
            check(coordinator.posture == .compactWings, "After cancelReply, hover exit returns posture from expandedCard to compactWings")

            // Disabling keepUntilDismissed clears history so collapsing active and re-enabling does not resurrect old items
            plugin.keepUntilDismissed = false
            check(plugin.history.isEmpty, "Disabling keepUntilDismissed clears kept history")
            coordinator.handleNotchClicked()
            coordinator.handleExpandedSwipe(.up)
            plugin.keepUntilDismissed = true
            check(plugin.history.isEmpty, "Re-enabling keepUntilDismissed after toast collapse does not resurrect cleared notifications")

            plugin.clearAllHistory()
            plugin.keepUntilDismissed = false

            plugin.stop()
            print("  [PASS] testNotificationBridgePlugin")
        }

        // 8. Test Now Playing Track Change Animation Models, Directions, and Settings
        do {
            let trackA = NowPlayingTrack(title: "Track 1", artist: "Artist A")
            let trackB = NowPlayingTrack(title: "Track 1", artist: "Artist B")
            let trackC = NowPlayingTrack(title: "Track 2", artist: "Artist A")

            check(trackA.trackIdentity != trackB.trackIdentity, "Different artists must have distinct track identities")
            check(trackA.trackIdentity != trackC.trackIdentity, "Different titles must have distinct track identities")
            check(trackA.trackIdentity == "\(trackA.title)///\(trackA.artist)", "Identity format check")

            let mediaService = MediaRemoteStreamService()
            check(mediaService.latestTrackChange == nil, "Initial latestTrackChange should be nil")

            mediaService.setSimulatedTrack(trackA)
            check(mediaService.latestTrackChange == nil, "First simulated track load should not emit track change event")

            mediaService.setSimulatedTrack(trackB, direction: .forward)
            check(mediaService.latestTrackChange?.title == "Track 1", "Track change title should match")
            check(mediaService.latestTrackChange?.artist == "Artist B", "Track change artist should match")
            check(mediaService.latestTrackChange?.direction == .forward, "Forward direction should match")

            mediaService.sendCommand(.previousTrack)
            mediaService.setSimulatedTrack(trackC)
            check(mediaService.latestTrackChange?.direction == .backward, "Track change after previousTrack command should infer backward direction")

            let nowPlayingDefaultsKeys = [
                "island.plugin.com.island.plugin.nowplaying.enabled",
                "island.nowplaying.showWhenPaused",
                "island.nowplaying.themeStyle",
                "island.nowplaying.disableWaveform",
                "island.nowplaying.hideSourceActive",
                "island.nowplaying.auxAction",
                "island.nowplaying.waveformIntensity",
                "island.nowplaying.showTrackInfoOnChange",
                "island.nowplaying.trackInfoDuration"
            ]
            for key in nowPlayingDefaultsKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in nowPlayingDefaultsKeys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }

            let plugin = NowPlayingPlugin()
            check(plugin.showTrackInfoOnChange == true, "showTrackInfoOnChange should default to true")
            check(plugin.trackInfoDisplayDuration == 2.5, "trackInfoDisplayDuration should default to 2.5 seconds")
            check(plugin.waveformIntensity == .medium, "waveformIntensity should default to .medium")

            plugin.waveformIntensity = .calm
            check(plugin.waveformIntensity == .calm, "waveformIntensity update to .calm")
            plugin.waveformIntensity = .intense
            check(plugin.waveformIntensity == .intense, "waveformIntensity update to .intense")

            // Verify AudioWaveformView initializes across all intensities playing and paused
            for intensity in WaveformIntensity.allCases {
                let wavePlaying = AudioWaveformView(isPlaying: true, tintColor: .accentColor, intensity: intensity)
                _ = wavePlaying.body
                let wavePaused = AudioWaveformView(isPlaying: false, tintColor: .accentColor, intensity: intensity)
                _ = wavePaused.body
            }

            plugin.trackInfoDisplayDuration = 4.5
            check(plugin.trackInfoDisplayDuration == 4.5, "trackInfoDisplayDuration update")

            let coordinator = NotchStateCoordinator()
            plugin.start(coordinator: coordinator)

            plugin.simulateNextTrack()
            check(coordinator.persistentActivity != nil, "Persistent activity should be published for simulated track")
            check(coordinator.persistentActivity?.wingSizes.leftWidth ?? 0 > 34, "Left wing should expand to reveal track info")
            check(plugin.mediaService.latestTrackChange?.direction == .forward, "simulateNextTrack direction should be forward")

            plugin.simulatePreviousTrack()
            check(coordinator.persistentActivity?.wingSizes.leftWidth ?? 0 > 34, "Left wing should remain expanded on previous track")
            check(plugin.mediaService.latestTrackChange?.direction == .backward, "simulatePreviousTrack direction should be backward")

            plugin.showTrackInfoOnChange = false
            plugin.clearSimulatedTrack()
            plugin.simulateTrack()
            check(coordinator.persistentActivity?.wingSizes.leftWidth == 34, "Left wing should stay standard 34 width when track info reveal is disabled")

            // Expanded swipe gestures control Next / Previous track when swipeToSkipMediaEnabled is true
            let previousSwipeToSkip = UserDefaults.standard.object(forKey: "island.gestures.swipeToSkip")
            coordinator.handleNotchClicked()
            coordinator.swipeToSkipMediaEnabled = true
            coordinator.handleExpandedSwipe(.left)
            check(plugin.mediaService.lastNavCommand == .nextTrack, "Swiping left on expanded Now Playing sends nextTrack")
            check(plugin.mediaService.latestNavigationPulse?.direction == .forward, "Swiping left emits forward navigation pulse")
            coordinator.handleExpandedSwipe(.right)
            check(plugin.mediaService.lastNavCommand == .previousTrack, "Swiping right on expanded Now Playing sends previousTrack")
            check(plugin.mediaService.latestNavigationPulse?.direction == .backward, "Swiping right emits backward navigation pulse")

            let expandedCard = NowPlayingExpandedCardView(
                mediaService: plugin.mediaService,
                themeStyle: plugin.themeStyle,
                auxiliaryAction: plugin.auxiliaryAction,
                waveformIntensity: plugin.waveformIntensity
            )
            _ = expandedCard.body

            coordinator.swipeToSkipMediaEnabled = false
            plugin.simulateTrack()
            coordinator.handleExpandedSwipe(.left)
            check(plugin.mediaService.currentTrack?.elapsedTime == 122, "Swipe left does not skip track when swipeToSkipMediaEnabled is false")
            if let previousSwipeToSkip {
                UserDefaults.standard.set(previousSwipeToSkip, forKey: "island.gestures.swipeToSkip")
            } else {
                UserDefaults.standard.removeObject(forKey: "island.gestures.swipeToSkip")
            }
            coordinator.handleHoverExited()

            plugin.stop()
            check(coordinator.persistentActivity == nil, "Persistent activity should clear on stop")
            print("  [PASS] testNowPlayingTrackChangeAnimationAndSettings")
        }

        print("==> Test Results: \(passed) checks passed, \(failed) failed.")
        if failed > 0 {
            Foundation.exit(1)
        }
    }
}
