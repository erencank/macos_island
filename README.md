# Island — Native MacBook Dynamic Island

**Island** is a native macOS application (`Swift` / `SwiftUI` / `AppKit`) that turns the MacBook's physical camera notch (or top-center menu bar on external displays) into an interactive, fluidly animated Dynamic Island—inspired by Alcove and iOS Dynamic Island.

Full architectural details are documented in [ARCHITECTURE_AND_DESIGN.md](file:///Users/erencankanmaz/Documents/island/ARCHITECTURE_AND_DESIGN.md).

---

## Features

- **Fluid 120Hz ProMotion Morphing**: Custom [`NotchSilhouetteShape`](file:///Users/erencankanmaz/Documents/island/Sources/IslandCore/Animation/NotchSilhouetteShape.swift) with concave top "ears" and continuous rounded bottom corners, rendered inside a click-through borderless `NSPanel` above the menu bar.
- **Universal "Now Playing" Media Widget**:
  - Works with **Spotify**, **Apple Music**, and **browsers** (Safari, Chrome, Arc, Dia, etc.) via a bundled `MediaRemote` dylib bridge + AppleScript fallback.
  - **Compact Wings**: Displays mini album art on the left of the notch and a color-tinted animated audio equalizer (`Calm`, `Medium`, `Intense`) on the right, with optional track title/artist reveal on track changes.
  - **Hover / Click Expansion**: Expands into a full media card with high-res album artwork, elapsed/remaining scrubber, transport controls, and audio output route indicator.
- **App Notifications & Native Banner Hiding**:
  - Dedicated integrations for **Slack**, **Microsoft Teams** (messages and incoming calls with `Accept` / `Decline`), **Microsoft Outlook** (emails with subject + 2-line body preview), and **WhatsApp** (direct messages, group chats, and calls), plus an optional **Other Apps** fallback.
  - Per-app **Hide system banner** option parks the Notification Center banner window offscreen when idle so native banners never flash on screen while still transitioning naturally into the macOS Notification Center tray.
- **AirDrop Dropzone & Incoming Transfer Receiver**:
  - Drag files to the top of the screen to expand the notch into an outgoing AirDrop dropzone.
  - Intercepts incoming AirDrop file and link transfers (`Accept` / `Decline` / `Open` / `Show in Finder`) with live progress inside the Island.
- **System HUD Replacement (Sound & Display)**:
  - Intercepts hardware Volume (`F10`/`F11`/`F12`) and Brightness (`F1`/`F2`) keys via `CGEventTap` to suppress the native macOS HUD and render a horizontal progress bar inside the notch.
- **System Status Plugins**:
  - **Lock Screen Widget**: Animated padlock (`lock.fill` / `lock.open.fill`) when locking and unlocking your Mac.
  - **Battery & Power**: Charging indicator, Low Battery alerts (`20%` / `10%`), and Low Power Mode status.
  - **Wi-Fi & Bluetooth Status**: Real-time Wi-Fi connection banners and Bluetooth device connect/disconnect HUDs with battery percentages and device-category icons.
- **Multi-Monitor & Geometry Tuning**:
  - Choose between **Automatic (Notched Built-in Display)**, **Follow Active Cursor**, or a **Specific Display**, with fine-grained sliders for notch width, height, and hover exit margin.

---

## Prerequisites

- **macOS 14.0 (Sonoma) or newer** (compatible with macOS 15 Sequoia and macOS 26 Tahoe).
- **Swift 5.10+ / Xcode Command Line Tools** (builds directly via `swift build` and standard macOS system tools).

---

## Quick Start (Development & Testing)

### 1. Run Automated Unit Tests
Validate the geometry engine, priority preemption state machine, notification parsers, AirDrop state machine, and Now Playing animations:
```bash
./Scripts/run-tests.sh
```

### 2. Build & Run in Development Mode
Because macOS requires an `.app` bundle (with an `Info.plist`) to register Accessibility permissions (`CGEventTap` / `AXObserver`) and float above the menu bar, use the development helper script:
```bash
./Scripts/run-dev.sh
```
**What `./Scripts/run-dev.sh` does:**
1. Compiles `libIslandMediaRemoteBridge.dylib` and the Swift `Island` executable (`./Scripts/build-app.sh debug`).
2. Packages `build/Island.app` with its `Info.plist`, resources, and ad-hoc code signature (`codesign --force --deep --sign -`).
3. Launches `build/Island.app` with the Settings window open.

### 3. Packaging a Distributable `.dmg`
To build a release-optimized `.app` bundle and package it into a native macOS disk image (`build/Island.dmg`):
```bash
./Scripts/build-dmg.sh
```

---

## Adding a New App Notification Parser

Dedicated app notification parsers live in `Sources/IslandCore/Plugins/Notifications/Parsers/` and conform to [`AppNotificationParser`](file:///Users/erencankanmaz/Documents/island/Sources/IslandCore/Plugins/Notifications/NotificationParsers.swift#L3-L6):

1. Create `Sources/IslandCore/Plugins/Notifications/Parsers/MyAppNotificationParser.swift` conforming to `AppNotificationParser`.
2. Register `MyAppNotificationParser()` in [`NotificationParserSet.init`](file:///Users/erencankanmaz/Documents/island/Sources/IslandCore/Plugins/Notifications/NotificationParsers.swift#L125-L134).
3. Add enable and hide-banner toggles in [`NotificationBridgePlugin.swift`](file:///Users/erencankanmaz/Documents/island/Sources/IslandCore/Plugins/Notifications/NotificationBridgePlugin.swift) and [`SettingsWindowView.swift`](file:///Users/erencankanmaz/Documents/island/Sources/IslandCore/SettingsUI/SettingsWindowView.swift).

---

## Adding a New Notch Plugin

To add a new top-level notch integration conforming to [`NotchPlugin`](file:///Users/erencankanmaz/Documents/island/Sources/IslandCore/Coordinator/NotchStateCoordinator.swift#L95-L104):

1. Create a class in `Sources/IslandCore/Plugins/` conforming to `NotchPlugin`:
   ```swift
   @MainActor
   public final class MyCustomPlugin: ObservableObject, NotchPlugin {
       public let id = "com.island.plugin.custom"
       public let displayName = "My Custom Integration"
       public let symbolName = "star.fill"
       @Published public var isEnabled: Bool = true
       private weak var coordinator: NotchStateCoordinator?

       public func start(coordinator: NotchStateCoordinator) {
           self.coordinator = coordinator
       }

       public func stop() {
           coordinator?.clearPersistentActivity(pluginID: id)
       }
   }
   ```
2. Register the plugin in [`NotchPluginRegistry`](file:///Users/erencankanmaz/Documents/island/Sources/IslandCore/Coordinator/NotchPluginRegistry.swift) and [`main.swift`](file:///Users/erencankanmaz/Documents/island/Sources/Island/main.swift).
3. Publish activities via `coordinator.publishPersistentActivity(_:)` or `coordinator.publishTransientHUD(_:)`.
