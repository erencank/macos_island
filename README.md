# Island — Native MacBook Dynamic Island

**Island** is a native macOS application (`Swift` / `SwiftUI` / `AppKit`) that turns the MacBook's physical camera notch (or top-center menu bar on external displays) into an interactive, fluidly animated Dynamic Island—inspired by Alcove and iOS Dynamic Island.

Full architectural details are documented in [ARCHITECTURE_AND_DESIGN.md](file:///Users/erencankanmaz/Documents/island/ARCHITECTURE_AND_DESIGN.md).

---

## Features

- **Fluid 120Hz ProMotion Morphing**: Custom `NotchSilhouetteShape` with concave top "ears" and continuous rounded bottom corners, rendered inside a click-through borderless `NSPanel` above the menu bar.
- **Universal "Now Playing" Media Widget**:
  - Works with **Spotify**, **Apple Music**, and **browsers** (Safari, Chrome, Arc, Dia, etc.) via a bundled `MediaRemote` bridge + ScriptingBridge fallback.
  - **Compact Wings**: Displays mini album art on the left of the notch and a color-tinted animated audio equalizer on the right.
  - **Hover / Click Expansion (`50ms` response)**: Expands into a full media card with high-res album artwork, elapsed/remaining scrubber, play/pause/skip/shuffle controls, and audio output indicator.
- **System HUD Replacement (Sound & Display)**:
  - Intercepts hardware Volume (`F10`/`F11`/`F12`) and Brightness (`F1`/`F2`) keys via `CGEventTap` to suppress the native macOS corner HUD and render a sleek horizontal progress bar directly inside the notch.
  - Includes an interactive Accessibility permission popover flow.
- **System Status Plugins**:
  - **Lock Screen Widget**: Animated padlock (`lock.fill` / `lock.open.fill`) when locking and unlocking your Mac.
  - **Battery & Power**: Charging indicator, Low Battery alerts (`20%` / `10%`), and Low Power Mode status.
  - **Wi-Fi Status**: Real-time Wi-Fi connection/disconnection HUD banners.
- **Multi-Monitor Support**:
  - Choose between **Automatic (Notched Built-in Display)**, **Follow Active Cursor**, or a **Specific Display**.
  - External monitors without a physical notch render a sleek floating pill at the top center of the screen.

---

## Prerequisites

- **macOS 14.0 (Sonoma) or newer** (fully compatible with macOS 15 Sequoia and macOS 26 Tahoe).
- **Swift 6.0+ / Xcode Command Line Tools** (no full Xcode installation required; builds directly via `swift build` and standard macOS system tools).

---

## Quick Start (Development & Testing)

### 1. Run Automated Unit Tests
Validate the geometry engine, priority preemption state machine, and notch silhouette path generator:
```bash
./Scripts/run-tests.sh
```

### 2. Build & Run in Development Mode
Because macOS requires an `.app` bundle (with an `Info.plist`) to register Accessibility permissions (`CGEventTap`) and float above the menu bar properly, use the development helper script:
```bash
./Scripts/run-dev.sh
```
**What `./Scripts/run-dev.sh` does:**
1. Compiles the Swift executable (`swift build`) and the `MediaRemoteAdapter` bridge.
2. Packages `build/Island.app` with its `Info.plist`, resources, and ad-hoc code signature (`codesign --force --deep --sign -`).
3. Launches `build/Island.app` and streams live structured logs to your terminal.

### 3. Interactive Preview & Simulation Mode
When developing or testing UI animations without waiting for a real low-battery event or locking your screen:
1. Click the **Island icon** in your macOS Menu Bar (or press `Cmd + ,` while the settings window is focused) to open **Island Settings**.
2. Go to the **Developer / Preview** tab in Settings.
3. Click any of the simulation buttons:
   - **Simulate Volume / Brightness HUD**
   - **Simulate Now Playing Track**
   - **Simulate Lock / Unlock Screen**
   - **Simulate Low Battery / Charging / Low Power Mode**
   - **Simulate Wi-Fi Toggle**

---

## Packaging a Distributable `.dmg`

To build a release-optimized `.app` bundle and package it into a native macOS disk image (`build/Island.dmg`):

```bash
./Scripts/build-dmg.sh
```

After completion:
- **App Bundle**: `build/Island.app`
- **Disk Image**: `build/Island.dmg` (includes `Island.app` and an `Applications` drop-link).

---

## Granting Permissions (System HUD Replacement)

To replace the native macOS Volume and Brightness HUDs:
1. Open **Island Settings** from the menu bar icon.
2. Toggle on **Replace Sound HUD** or **Replace Display HUD**.
3. If Island does not yet have Accessibility permission, a popover will appear: *"Island needs your permission to replace the system HUDs."*
4. Click **Ask Permission...** -> macOS will open **System Settings > Privacy & Security > Accessibility**.
5. Enable the toggle next to **Island.app**. Island automatically detects the permission change within 1 second and activates the HUD interceptor.

> [!TIP]
> **Rebuilding during development:** When you rebuild `Island.app` locally, ad-hoc signing uses a stable bundle identifier (`com.island.app`). If macOS TCC ever caches an old signature after a rebuild, run `tccutil reset Accessibility com.island.app` in Terminal and toggle the permission back on in System Settings.

---

## Adding a New Plugin

Island uses a modular plugin architecture. To add a new integration (e.g., Calendar, Pomodoro Timer, AirDrop dropzone):

1. Create a new class in `Sources/IslandApp/Plugins/` conforming to [`NotchPlugin`](file:///Users/erencankanmaz/Documents/island/Sources/IslandApp/Plugins/NotchPlugin.swift):
   ```swift
   @MainActor
   public final class MyCustomPlugin: NotchPlugin {
       public let id = "com.island.plugin.custom"
       public let displayName = "My Custom Integration"
       public var isEnabled: Bool = true
       private weak var coordinator: NotchStateCoordinator?

       public func start(coordinator: NotchStateCoordinator) {
           self.coordinator = coordinator
           // Subscribe to system notifications or timers here
       }

       public func stop() {
           coordinator?.clearActivity(pluginID: id)
       }
   }
   ```
2. Register the plugin in `NotchPluginRegistry.registerDefaultPlugins()`.
3. Emit a `compactWings`, `transientHUD`, or `expandedCard` presentation via `coordinator.publish(...)`.
