import AppKit
import Combine
import CoreGraphics
import Foundation

public enum DisplaySelectionMode: String, CaseIterable, Identifiable, Codable {
    case automaticNotch = "automaticNotch"
    case followCursor = "followCursor"
    case specificDisplay = "specificDisplay"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automaticNotch:
            return "Automatic (Prefer Notched Display)"
        case .followCursor:
            return "Follow Active Cursor"
        case .specificDisplay:
            return "Specific Display"
        }
    }
}

public struct ScreenMetricsInput: Equatable, Sendable {
    public let displayID: UInt32
    public let localizedName: String
    public let screenFrame: CGRect
    public let topSafeAreaInset: CGFloat
    public let auxiliaryTopLeftArea: CGRect?
    public let auxiliaryTopRightArea: CGRect?

    public init(
        displayID: UInt32,
        localizedName: String,
        screenFrame: CGRect,
        topSafeAreaInset: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.screenFrame = screenFrame
        self.topSafeAreaInset = topSafeAreaInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }
}

public struct NotchGeometry: Equatable, Sendable {
    public let displayID: UInt32
    public let displayName: String
    public let screenFrame: CGRect
    public let hasPhysicalNotch: Bool
    /// Exact frame of the physical notch (or synthesized top-center floating pill on external monitors) in global screen coordinates.
    public let notchFrame: CGRect
    /// Bounding canvas frame for the transparent borderless NSPanel in global screen coordinates.
    public let canvasWindowFrame: CGRect

    public static let canvasWidth: CGFloat = 560
    public static let canvasHeight: CGFloat = 260
    public static let fallbackPillWidth: CGFloat = 184
    public static let fallbackPillHeight: CGFloat = 32

    public static func calculate(from input: ScreenMetricsInput) -> NotchGeometry {
        let screenFrame = input.screenFrame
        let hasNotch: Bool
        let notchRect: CGRect

        if input.topSafeAreaInset > 0,
           let topLeft = input.auxiliaryTopLeftArea,
           let topRight = input.auxiliaryTopRightArea,
           topRight.minX > topLeft.maxX {
            hasNotch = true
            let width = topRight.minX - topLeft.maxX
            let height = max(input.topSafeAreaInset, screenFrame.maxY - topLeft.maxY, 32)
            let originX = topLeft.maxX
            let originY = screenFrame.maxY - height
            notchRect = CGRect(x: originX, y: originY, width: width, height: height)
        } else if input.topSafeAreaInset > 0 {
            hasNotch = true
            let width: CGFloat = 188
            let height = max(input.topSafeAreaInset, 32)
            let originX = screenFrame.midX - (width / 2.0)
            let originY = screenFrame.maxY - height
            notchRect = CGRect(x: originX, y: originY, width: width, height: height)
        } else {
            hasNotch = false
            let width = Self.fallbackPillWidth
            let height = Self.fallbackPillHeight
            let originX = screenFrame.midX - (width / 2.0)
            let originY = screenFrame.maxY - height
            notchRect = CGRect(x: originX, y: originY, width: width, height: height)
        }

        let canvasOriginX = notchRect.midX - (Self.canvasWidth / 2.0)
        let canvasOriginY = screenFrame.maxY - Self.canvasHeight
        let canvasFrame = CGRect(
            x: canvasOriginX,
            y: canvasOriginY,
            width: Self.canvasWidth,
            height: Self.canvasHeight
        )

        return NotchGeometry(
            displayID: input.displayID,
            displayName: input.localizedName,
            screenFrame: screenFrame,
            hasPhysicalNotch: hasNotch,
            notchFrame: notchRect,
            canvasWindowFrame: canvasFrame
        )
    }

    public static func selectScreen(
        from screens: [ScreenMetricsInput],
        mode: DisplaySelectionMode,
        preferredDisplayID: UInt32?,
        cursorLocation: CGPoint?
    ) -> ScreenMetricsInput? {
        guard !screens.isEmpty else { return nil }

        switch mode {
        case .automaticNotch:
            if let notched = screens.first(where: { $0.topSafeAreaInset > 0 }) {
                return notched
            }
            return screens.first

        case .followCursor:
            if let cursor = cursorLocation,
               let hovered = screens.first(where: { $0.screenFrame.contains(cursor) }) {
                return hovered
            }
            return screens.first(where: { $0.topSafeAreaInset > 0 }) ?? screens.first

        case .specificDisplay:
            if let preferredID = preferredDisplayID,
               let match = screens.first(where: { $0.displayID == preferredID }) {
                return match
            }
            return screens.first(where: { $0.topSafeAreaInset > 0 }) ?? screens.first
        }
    }
}

@MainActor
public final class ScreenGeometryMonitor: ObservableObject {
    @Published public private(set) var availableScreens: [ScreenMetricsInput] = []
    @Published public private(set) var activeGeometry: NotchGeometry
    @Published public var selectionMode: DisplaySelectionMode {
        didSet {
            UserDefaults.standard.set(selectionMode.rawValue, forKey: "island.displaySelectionMode")
            refreshGeometry()
        }
    }
    @Published public var preferredDisplayID: UInt32? {
        didSet {
            if let id = preferredDisplayID {
                UserDefaults.standard.set(Int(id), forKey: "island.preferredDisplayID")
            } else {
                UserDefaults.standard.removeObject(forKey: "island.preferredDisplayID")
            }
            refreshGeometry()
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var cursorMonitorTimer: Timer?

    public init() {
        let savedModeRaw = UserDefaults.standard.string(forKey: "island.displaySelectionMode") ?? DisplaySelectionMode.automaticNotch.rawValue
        let initialMode = DisplaySelectionMode(rawValue: savedModeRaw) ?? .automaticNotch
        self.selectionMode = initialMode

        let savedID = UserDefaults.standard.object(forKey: "island.preferredDisplayID") as? Int
        self.preferredDisplayID = savedID.map { UInt32($0) }

        let fallbackInput = ScreenMetricsInput(
            displayID: 1,
            localizedName: "Built-in Display",
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            topSafeAreaInset: 37,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 945, width: 662, height: 37),
            auxiliaryTopRightArea: CGRect(x: 850, y: 945, width: 662, height: 37)
        )
        self.activeGeometry = NotchGeometry.calculate(from: fallbackInput)

        refreshGeometry()
        observeScreenChanges()
    }

    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshGeometry()
            }
            .store(in: &cancellables)

        cursorMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.selectionMode == .followCursor else { return }
                self.refreshGeometry()
            }
        }
    }

    public func refreshGeometry() {
        let inputs = NSScreen.screens.map { screen -> ScreenMetricsInput in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return ScreenMetricsInput(
                displayID: id,
                localizedName: screen.localizedName,
                screenFrame: screen.frame,
                topSafeAreaInset: screen.safeAreaInsets.top,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea
            )
        }

        self.availableScreens = inputs

        let mouseLocation = NSEvent.mouseLocation
        guard let selected = NotchGeometry.selectScreen(
            from: inputs,
            mode: selectionMode,
            preferredDisplayID: preferredDisplayID,
            cursorLocation: mouseLocation
        ) else {
            return
        }

        let calculated = NotchGeometry.calculate(from: selected)
        if calculated != activeGeometry {
            activeGeometry = calculated
            IslandLogger.window.info("Updated notch geometry for display \(calculated.displayName, privacy: .public) (hasNotch: \(calculated.hasPhysicalNotch))")
        }
    }
}
