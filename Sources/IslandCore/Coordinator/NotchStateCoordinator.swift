import AppKit
import Combine
import Foundation
import SwiftUI

public enum NotchPriority: Int, Comparable, Sendable {
    case background = 10   // Persistent Now Playing, background timers
    case normal = 50       // Wi-Fi toggle, Bluetooth connected
    case high = 80         // Volume / Brightness HUD
    case critical = 100    // Low Battery (10%), Screen Lock / Unlock

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum NotchPosture: String, Equatable, Sendable {
    case resting
    case compactWings
    case transientHUD
    case expandedCard
}

public enum NotchTuningAxis: String, Equatable, Sendable {
    case width
    case height
    case exitMargin
}

/// Content-fitted wing sizing for the left and right sides of the physical notch.
public struct NotchWingSizes: Equatable, Sendable {
    public let leftWidth: CGFloat
    public let rightWidth: CGFloat

    public init(leftWidth: CGFloat, rightWidth: CGFloat) {
        self.leftWidth = leftWidth
        self.rightWidth = rightWidth
    }

    public static let zero = NotchWingSizes(leftWidth: 0, rightWidth: 0)
}

public struct NotchLayoutGeometry: Equatable, Sendable {
    public let leftWingWidth: CGFloat
    public let rightWingWidth: CGFloat
    public let totalWidth: CGFloat
    public let height: CGFloat
    /// Horizontal offset from the physical notch center so left wing extends by `leftWingWidth`
    /// and right wing extends by `rightWingWidth` independently.
    public var horizontalCenterOffset: CGFloat {
        (rightWingWidth - leftWingWidth) / 2.0
    }
}

public struct NotchActivityPayload: Identifiable {
    public let id: String
    public let pluginID: String
    public let priority: NotchPriority
    public let posture: NotchPosture
    public let duration: TimeInterval?
    public let wingSizes: NotchWingSizes
    public let compactLeadingView: AnyView?
    public let compactTrailingView: AnyView?
    public let hudView: AnyView?
    public let expandedView: AnyView?
    public let accentColor: Color

    public init(
        id: String = UUID().uuidString,
        pluginID: String,
        priority: NotchPriority,
        posture: NotchPosture,
        duration: TimeInterval? = nil,
        wingSizes: NotchWingSizes = NotchWingSizes(leftWidth: 38, rightWidth: 38),
        compactLeadingView: AnyView? = nil,
        compactTrailingView: AnyView? = nil,
        hudView: AnyView? = nil,
        expandedView: AnyView? = nil,
        accentColor: Color = .white
    ) {
        self.id = id
        self.pluginID = pluginID
        self.priority = priority
        self.posture = posture
        self.duration = duration
        self.wingSizes = wingSizes
        self.compactLeadingView = compactLeadingView
        self.compactTrailingView = compactTrailingView
        self.hudView = hudView
        self.expandedView = expandedView
        self.accentColor = accentColor
    }
}

@MainActor
public protocol NotchPlugin: AnyObject, Identifiable {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }
    var isEnabled: Bool { get set }

    func start(coordinator: NotchStateCoordinator)
    func stop()
}

@MainActor
public final class NotchStateCoordinator: ObservableObject {
    @Published public private(set) var posture: NotchPosture = .resting
    @Published public private(set) var isHovering: Bool = false
    /// Subtle scale/press tension while the cursor hovers during the 50ms delay before opening
    @Published public private(set) var isPressTensionActive: Bool = false

    @Published public private(set) var persistentActivity: NotchActivityPayload?
    @Published public private(set) var activeTransientHUD: NotchActivityPayload?

    /// Active visual calibration mode shown in the notch when adjusting Tuning sliders in Settings
    @Published public private(set) var activeTuningAxis: NotchTuningAxis?

    /// Configurable hover delay in milliseconds (default 50ms)
    @Published public var hoverExpandDelayMs: Double {
        didSet {
            UserDefaults.standard.set(hoverExpandDelayMs, forKey: "island.hoverExpandDelayMs")
        }
    }

    /// Configurable distance (in points/pixels) outside the expanded island before it collapses (default 36px)
    @Published public var hoverExitMarginPx: Double {
        didSet {
            UserDefaults.standard.set(hoverExitMarginPx, forKey: "island.hoverExitMarginPx")
            triggerTuningPreview(.exitMargin)
        }
    }

    /// Fine-tuning offset (in pixels) for the unexpanded notch width (-16px ... +24px, default 0px)
    @Published public var notchWidthOffsetPx: Double {
        didSet {
            UserDefaults.standard.set(notchWidthOffsetPx, forKey: "island.tuning.widthOffsetPx")
            triggerTuningPreview(.width)
        }
    }

    /// Fine-tuning offset (in pixels) for the unexpanded notch height (-12px ... +20px, default 0px)
    @Published public var notchHeightOffsetPx: Double {
        didSet {
            UserDefaults.standard.set(notchHeightOffsetPx, forKey: "island.tuning.heightOffsetPx")
            triggerTuningPreview(.height)
        }
    }

    @Published public var expandOnHoverEnabled: Bool {
        didSet {
            UserDefaults.standard.set(expandOnHoverEnabled, forKey: "island.behaviour.expandOnHover")
        }
    }

    @Published public var hapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticFeedbackEnabled, forKey: "island.behaviour.haptics")
        }
    }

    @Published public var showContrastOutline: Bool {
        didSet {
            UserDefaults.standard.set(showContrastOutline, forKey: "island.behaviour.contrastOutline")
        }
    }

    @Published public var hideFromScreenCapture: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenCapture, forKey: "island.behaviour.hideScreenCapture")
        }
    }

    @Published public var forceSimulatedNotch: Bool {
        didSet {
            UserDefaults.standard.set(forceSimulatedNotch, forKey: "island.behaviour.forceSimulatedNotch")
        }
    }

    @Published public var swipeToDismissEnabled: Bool {
        didSet {
            UserDefaults.standard.set(swipeToDismissEnabled, forKey: "island.gestures.swipeToDismiss")
        }
    }

    @Published public var swipeToSkipMediaEnabled: Bool {
        didSet {
            UserDefaults.standard.set(swipeToSkipMediaEnabled, forKey: "island.gestures.swipeToSkip")
        }
    }

    private var transientDismissTask: Task<Void, Never>?
    private var hoverExpandTask: Task<Void, Never>?
    private var tuningPreviewDismissTask: Task<Void, Never>?

    public init(hoverExpandDelayMs: Double? = nil) {
        if let customDelay = hoverExpandDelayMs {
            self.hoverExpandDelayMs = customDelay
        } else if UserDefaults.standard.object(forKey: "island.hoverExpandDelayMs") != nil {
            self.hoverExpandDelayMs = UserDefaults.standard.double(forKey: "island.hoverExpandDelayMs")
        } else {
            self.hoverExpandDelayMs = 50.0
        }

        if UserDefaults.standard.object(forKey: "island.hoverExitMarginPx") != nil {
            self.hoverExitMarginPx = UserDefaults.standard.double(forKey: "island.hoverExitMarginPx")
        } else {
            self.hoverExitMarginPx = 36.0
        }

        if UserDefaults.standard.object(forKey: "island.tuning.widthOffsetPx") != nil {
            self.notchWidthOffsetPx = UserDefaults.standard.double(forKey: "island.tuning.widthOffsetPx")
        } else {
            self.notchWidthOffsetPx = 0.0
        }

        if UserDefaults.standard.object(forKey: "island.tuning.heightOffsetPx") != nil {
            self.notchHeightOffsetPx = UserDefaults.standard.double(forKey: "island.tuning.heightOffsetPx")
        } else {
            self.notchHeightOffsetPx = 0.0
        }

        self.expandOnHoverEnabled = UserDefaults.standard.object(forKey: "island.behaviour.expandOnHover") as? Bool ?? true
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: "island.behaviour.haptics") as? Bool ?? false
        self.showContrastOutline = UserDefaults.standard.object(forKey: "island.behaviour.contrastOutline") as? Bool ?? false
        self.hideFromScreenCapture = UserDefaults.standard.object(forKey: "island.behaviour.hideScreenCapture") as? Bool ?? false
        self.forceSimulatedNotch = UserDefaults.standard.object(forKey: "island.behaviour.forceSimulatedNotch") as? Bool ?? false
        self.swipeToDismissEnabled = UserDefaults.standard.object(forKey: "island.gestures.swipeToDismiss") as? Bool ?? true
        self.swipeToSkipMediaEnabled = UserDefaults.standard.object(forKey: "island.gestures.swipeToSkip") as? Bool ?? true
    }

    // MARK: - Live Visual Notch Tuning Overlay (Alcove-style Coral Pink Calibration)

    public func triggerTuningPreview(_ axis: NotchTuningAxis) {
        tuningPreviewDismissTask?.cancel()
        withAnimation(IslandSprings.hudProgress) {
            activeTuningAxis = axis
        }

        tuningPreviewDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(IslandSprings.collapse) {
                self.activeTuningAxis = nil
            }
        }
    }

    // MARK: - Activity Publishing (with smooth spring animations)

    public func publishPersistentActivity(_ payload: NotchActivityPayload) {
        let wasResting = (persistentActivity == nil)
        withAnimation(wasResting ? IslandSprings.expand : IslandSprings.hudProgress) {
            persistentActivity = payload
            recalculatePosture()
        }
    }

    public func clearPersistentActivity(pluginID: String) {
        guard persistentActivity?.pluginID == pluginID else { return }
        withAnimation(IslandSprings.collapse) {
            persistentActivity = nil
            // Do NOT force-close `isHovering` if the user's cursor is still inside the expanded card
            // (e.g. right after clicking Pause!). Let `handleHoverExited()` collapse it naturally
            // when the user moves their cursor out of the hover zone.
            recalculatePosture()
        }
    }

    public func presentTransientHUD(_ payload: NotchActivityPayload) {
        if let currentHUD = activeTransientHUD, payload.priority < currentHUD.priority {
            return
        }

        transientDismissTask?.cancel()
        withAnimation(IslandSprings.expand) {
            activeTransientHUD = payload
            recalculatePosture()
        }

        let duration = payload.duration ?? 1.65
        transientDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(IslandSprings.collapse) {
                self.activeTransientHUD = nil
                self.recalculatePosture()
            }
        }
    }

    // MARK: - Hover & Click Interaction (50ms Press Tension -> Expand)

    public func handleHoverEntered() {
        guard expandOnHoverEnabled else { return }
        guard !isHovering else { return }
        isHovering = true

        if hapticFeedbackEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }

        withAnimation(IslandSprings.tension) {
            isPressTensionActive = true
        }

        hoverExpandTask?.cancel()
        let delayNanoseconds = UInt64(max(0, hoverExpandDelayMs) * 1_000_000)

        hoverExpandTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self, self.isHovering else { return }
            withAnimation(IslandSprings.expand) {
                self.isPressTensionActive = false
                self.recalculatePosture()
            }
        }
    }

    public func handleHoverExited() {
        hoverExpandTask?.cancel()
        isHovering = false
        withAnimation(IslandSprings.collapse) {
            isPressTensionActive = false
            recalculatePosture()
        }
    }

    public func handleNotchClicked() {
        hoverExpandTask?.cancel()
        isHovering = true
        withAnimation(IslandSprings.expand) {
            isPressTensionActive = false
            posture = .expandedCard
        }
    }

    private func recalculatePosture() {
        if isHovering && !isPressTensionActive {
            posture = .expandedCard
            return
        }

        if let hud = activeTransientHUD {
            posture = hud.posture == .expandedCard ? .expandedCard : .transientHUD
            return
        }

        if persistentActivity != nil {
            posture = .compactWings
            return
        }

        posture = .resting
    }

    /// Computes the tuned base notch dimensions incorporating user calibration (`notchWidthOffsetPx` and `notchHeightOffsetPx`)
    public func tunedBaseNotchSize(for rawNotchSize: CGSize) -> CGSize {
        let width = max(120, rawNotchSize.width + CGFloat(notchWidthOffsetPx))
        let height = max(22, rawNotchSize.height + CGFloat(notchHeightOffsetPx))
        return CGSize(width: width, height: height)
    }

    /// Computes the asymmetric content-fitted layout for the notch in each posture
    public func targetLayout(for rawNotchSize: CGSize, hasPhysicalNotch: Bool) -> NotchLayoutGeometry {
        let tunedBase = tunedBaseNotchSize(for: rawNotchSize)
        let baseWidth = max(tunedBase.width, 140)
        let baseHeight = max(tunedBase.height, 24)

        // When calibrating width or height in Settings, show the exact unexpanded tuned notch silhouette
        // with zero artificial extra height so the red calibration shape matches the true boundary 1:1.
        if let tuning = activeTuningAxis, (tuning == .width || tuning == .height) {
            return NotchLayoutGeometry(
                leftWingWidth: 0,
                rightWingWidth: 0,
                totalWidth: baseWidth,
                height: baseHeight
            )
        }

        var leftWing: CGFloat = 0
        var rightWing: CGFloat = 0
        var height: CGFloat = baseHeight

        switch posture {
        case .resting:
            leftWing = 0
            rightWing = 0
            height = baseHeight

        case .compactWings:
            let wings = persistentActivity?.wingSizes ?? NotchWingSizes(leftWidth: 34, rightWidth: 34)
            leftWing = wings.leftWidth
            rightWing = wings.rightWidth
            height = baseHeight

        case .transientHUD:
            let wings = activeTransientHUD?.wingSizes ?? NotchWingSizes(leftWidth: 82, rightWidth: 82)
            leftWing = wings.leftWidth
            rightWing = wings.rightWidth
            height = max(baseHeight + 2, 36)

        case .expandedCard:
            leftWing = 98
            rightWing = 98
            height = 204
        }

        if isPressTensionActive && posture != .expandedCard {
            leftWing += 5
            rightWing += 5
            height += 2
        }

        return NotchLayoutGeometry(
            leftWingWidth: leftWing,
            rightWingWidth: rightWing,
            totalWidth: baseWidth + leftWing + rightWing,
            height: height
        )
    }

    public func targetDimensions(for baseNotchSize: CGSize, hasPhysicalNotch: Bool) -> CGSize {
        let layout = targetLayout(for: baseNotchSize, hasPhysicalNotch: hasPhysicalNotch)
        return CGSize(width: layout.totalWidth, height: layout.height)
    }
}
