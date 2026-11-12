import AppKit
import Combine
import SwiftUI

@MainActor
public final class NotchWindowController {
    private var panel: NotchPanel?
    private let coordinator: NotchStateCoordinator
    private let geometryMonitor: ScreenGeometryMonitor
    private let defaultExpandedContent: () -> AnyView
    public var onFileDragHoverChanged: ((Bool) -> Void)?
    public var onFilesDropped: (([URL]) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverPollTimer: Timer?
    private var isCursorInsideNotch: Bool = false
    private var isFileDragNearNotch: Bool = false
    private var lastCompletedDragChangeCount: Int = NSPasteboard(name: .drag).changeCount
    private var isLiveDragSessionActive: Bool = false
    private var scrollDeltaX: CGFloat = 0
    private var scrollDeltaY: CGFloat = 0
    private var didTriggerScrollGesture: Bool = false
    private var lastDiscreteScrollAt: Date = .distantPast

    public init(
        coordinator: NotchStateCoordinator,
        geometryMonitor: ScreenGeometryMonitor,
        defaultExpandedContent: @escaping () -> AnyView
    ) {
        self.coordinator = coordinator
        self.geometryMonitor = geometryMonitor
        self.defaultExpandedContent = defaultExpandedContent
    }

    public func show() {
        let initialGeo = geometryMonitor.activeGeometry
        let panel = NotchPanel(contentRect: initialGeo.canvasWindowFrame)

        let canvasView = NotchCanvasView(
            coordinator: coordinator,
            geometryMonitor: geometryMonitor,
            defaultExpandedContent: defaultExpandedContent
        )

        let hostingView = NotchHitTestHostingView(rootView: canvasView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: NotchGeometry.canvasWidth,
            height: NotchGeometry.canvasHeight
        )

        hostingView.activeHitRectProvider = { [weak self] in
            guard let self else {
                return .zero
            }
            if self.isFileDragNearNotch {
                return CGRect(x: 0, y: 0, width: NotchGeometry.canvasWidth, height: NotchGeometry.canvasHeight)
            }
            // Only intercept mouse clicks inside the window when the expanded card is open
            // or compact wings are visible. When resting/closed, return .zero so 100% of clicks pass through.
            guard self.coordinator.posture == .expandedCard || self.coordinator.posture == .compactWings else {
                return .zero
            }
            let geo = self.geometryMonitor.activeGeometry
            let layout = self.coordinator.targetLayout(
                for: geo.notchFrame.size,
                hasPhysicalNotch: geo.hasPhysicalNotch
            )
            let earPadding: CGFloat = 11
            let width = layout.totalWidth + (earPadding * 2)
            let height = layout.height
            let originX = ((NotchGeometry.canvasWidth - width) / 2.0) + layout.horizontalCenterOffset
            let originY = NotchGeometry.canvasHeight - height
            return CGRect(x: originX, y: originY, width: width, height: height)
        }

        hostingView.onFileDragEntered = { [weak self] in
            self?.setFileDragNearNotch(true)
        }
        hostingView.onFileDragExited = { [weak self] in
            guard let self else { return }
            if (NSEvent.pressedMouseButtons & 1) == 0 {
                self.lastCompletedDragChangeCount = NSPasteboard(name: .drag).changeCount
                self.isLiveDragSessionActive = false
                self.setFileDragNearNotch(false)
            }
        }
        hostingView.onFilesDropped = { [weak self] urls in
            guard let self else { return false }
            self.lastCompletedDragChangeCount = NSPasteboard(name: .drag).changeCount
            self.isLiveDragSessionActive = false
            self.setFileDragNearNotch(false)
            self.isCursorInsideNotch = true
            self.onFilesDropped?(urls)
            return true
        }

        // Start with ignoresMouseEvents = true when closed/resting so the transparent canvas
        // never blocks clicks on browser tabs, menu bar items, or app titlebars near the notch.
        panel.ignoresMouseEvents = (coordinator.posture != .expandedCard)
        panel.contentView = hostingView
        panel.setFrame(initialGeo.canvasWindowFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        // Dynamically toggle window-level click-through whenever the posture changes:
        // - When closed (.resting, .compactWings, .transientHUD): `ignoresMouseEvents = true` (zero invisible wall!)
        // - When open (.expandedCard) or a file drag is hovering near the notch: `ignoresMouseEvents = false`
        coordinator.$posture
            .receive(on: RunLoop.main)
            .sink { [weak self] newPosture in
                guard let self, let panel = self.panel else { return }
                let shouldCaptureClicks = (newPosture == .expandedCard) || self.isFileDragNearNotch || self.coordinator.isTextInputActive
                if panel.ignoresMouseEvents == shouldCaptureClicks {
                    panel.ignoresMouseEvents = !shouldCaptureClicks
                }
            }
            .store(in: &cancellables)

        coordinator.$isTextInputActive
            .receive(on: RunLoop.main)
            .sink { [weak self] isActive in
                guard let self, let panel = self.panel else { return }
                panel.allowsKeyFocus = isActive
                if isActive {
                    panel.ignoresMouseEvents = false
                    NSApp.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil)
                } else {
                    panel.resignKey()
                }
            }
            .store(in: &cancellables)

        coordinator.$hideFromScreenCapture
            .receive(on: RunLoop.main)
            .sink { [weak self] hideCapture in
                self?.panel?.sharingType = hideCapture ? .none : .readOnly
            }
            .store(in: &cancellables)

        geometryMonitor.$activeGeometry
            .receive(on: RunLoop.main)
            .sink { [weak self] updatedGeo in
                self?.panel?.setFrame(updatedGeo.canvasWindowFrame, display: true)
            }
            .store(in: &cancellables)

        startMouseHoverTracking()
    }

    /// Global screen-coordinate mouse tracking so hovering over the notch works 100% reliably
    /// even while `panel.ignoresMouseEvents = true` and another application is in the foreground.
    private func startMouseHoverTracking() {
        stopMouseHoverTracking()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.evaluateCursorLocation(eventType: event.type)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.type == .scrollWheel {
                    self.handleScrollWheelEvent(event)
                } else {
                    self.evaluateCursorLocation(eventType: event.type)
                }
            }
            return event
        }

        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateCursorLocation(eventType: nil)
            }
        }
    }

    private func stopMouseHoverTracking() {
        if let global = globalMouseMonitor {
            NSEvent.removeMonitor(global)
            globalMouseMonitor = nil
        }
        if let local = localMouseMonitor {
            NSEvent.removeMonitor(local)
            localMouseMonitor = nil
        }
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    private func handleScrollWheelEvent(_ event: NSEvent) {
        guard coordinator.posture == .expandedCard,
              event.window === panel,
              event.momentumPhase == [] else { return }

        if event.phase == .began {
            scrollDeltaX = 0
            scrollDeltaY = 0
            didTriggerScrollGesture = false
        }

        if event.phase == .ended || event.phase == .cancelled {
            scrollDeltaX = 0
            scrollDeltaY = 0
            didTriggerScrollGesture = false
            return
        }

        guard !didTriggerScrollGesture else { return }

        if event.phase == [] {
            let now = Date()
            guard now.timeIntervalSince(lastDiscreteScrollAt) >= 0.22 else { return }
            let dy = event.scrollingDeltaY
            let dx = event.scrollingDeltaX
            guard abs(dy) >= 2 || abs(dx) >= 2 else { return }
            lastDiscreteScrollAt = now
            dispatchScrollSwipe(dx: dx, dy: dy, inverted: event.isDirectionInvertedFromDevice)
            return
        }

        scrollDeltaX += event.scrollingDeltaX
        scrollDeltaY += event.scrollingDeltaY

        let threshold: CGFloat = 24
        guard abs(scrollDeltaY) >= threshold || abs(scrollDeltaX) >= threshold else { return }
        didTriggerScrollGesture = true
        dispatchScrollSwipe(dx: scrollDeltaX, dy: scrollDeltaY, inverted: event.isDirectionInvertedFromDevice)
    }

    private func dispatchScrollSwipe(dx: CGFloat, dy: CGFloat, inverted: Bool) {
        let physicalY = inverted ? dy : -dy
        let physicalX = inverted ? dx : -dx
        if abs(physicalY) >= abs(physicalX) {
            coordinator.handleExpandedSwipe(physicalY > 0 ? .down : .up)
        } else {
            coordinator.handleExpandedSwipe(physicalX > 0 ? .right : .left)
        }
    }

    private func setFileDragNearNotch(_ active: Bool) {
        guard isFileDragNearNotch != active else { return }
        isFileDragNearNotch = active
        if let panel {
            let shouldCaptureClicks = (coordinator.posture == .expandedCard) || active
            if panel.ignoresMouseEvents == shouldCaptureClicks {
                panel.ignoresMouseEvents = !shouldCaptureClicks
            }
        }
        onFileDragHoverChanged?(active)
    }

    private func evaluateFileDragProximity(mouseScreenPoint: CGPoint, geo: NotchGeometry) {
        let isLeftButtonDown = (NSEvent.pressedMouseButtons & 1) != 0
        let dragPboard = NSPasteboard(name: .drag)
        let currentChangeCount = dragPboard.changeCount

        guard isLeftButtonDown else {
            lastCompletedDragChangeCount = currentChangeCount
            isLiveDragSessionActive = false
            if isFileDragNearNotch {
                setFileDragNearNotch(false)
            }
            return
        }

        if !isLiveDragSessionActive {
            if currentChangeCount != lastCompletedDragChangeCount {
                let hasFiles = !NotchHitTestHostingView<AnyView>.extractFileURLs(from: dragPboard).isEmpty
                if hasFiles {
                    isLiveDragSessionActive = true
                } else {
                    lastCompletedDragChangeCount = currentChangeCount
                }
            }
        }

        guard isLiveDragSessionActive else {
            if isFileDragNearNotch {
                setFileDragNearNotch(false)
            }
            return
        }

        let dropTriggerWidth: CGFloat = isFileDragNearNotch ? 420 : 340
        let dropTriggerHeight: CGFloat = isFileDragNearNotch ? 235 : 120
        let dropTriggerRect = CGRect(
            x: geo.notchFrame.midX - (dropTriggerWidth / 2.0),
            y: geo.screenFrame.maxY - dropTriggerHeight,
            width: dropTriggerWidth,
            height: dropTriggerHeight
        )

        let insideDragZone = dropTriggerRect.contains(mouseScreenPoint)
        setFileDragNearNotch(insideDragZone)
    }

    private func evaluateCursorLocation(eventType: NSEvent.EventType?) {
        let mouseScreenPoint = NSEvent.mouseLocation
        let geo = geometryMonitor.activeGeometry

        evaluateFileDragProximity(mouseScreenPoint: mouseScreenPoint, geo: geo)
        if isFileDragNearNotch {
            return
        }

        let layout = coordinator.targetLayout(
            for: geo.notchFrame.size,
            hasPhysicalNotch: geo.hasPhysicalNotch
        )

        let earPadding: CGFloat = 11
        let activeWidth = layout.totalWidth + (earPadding * 2)
        let activeHeight = layout.height

        let globalNotchRect = CGRect(
            x: geo.notchFrame.midX - (activeWidth / 2.0) + layout.horizontalCenterOffset,
            y: geo.screenFrame.maxY - activeHeight,
            width: activeWidth,
            height: activeHeight
        )

        // IMPORTANT: Only apply the expanded `hoverExitMarginPx` buffer while the island is ACTUALLY open (`.expandedCard`).
        // When the island is closed, use the exact tight notch rect so we never create a large hover zone below the notch.
        let isExpandedOpen = (coordinator.posture == .expandedCard)
        let exitMargin = CGFloat(max(4.0, coordinator.hoverExitMarginPx))
        let hitZone = isExpandedOpen
            ? globalNotchRect.insetBy(dx: -exitMargin, dy: -exitMargin)
            : globalNotchRect

        // If the island is expanded and the user clicks outside the actual black card (even inside the exit margin buffer),
        // collapse immediately so their click goes straight to the underlying window.
        if isExpandedOpen, eventType == .leftMouseDown, !globalNotchRect.contains(mouseScreenPoint) {
            isCursorInsideNotch = false
            if coordinator.isTextInputActive {
                coordinator.isTextInputActive = false
            }
            coordinator.handleHoverExited()
            return
        }

        let inside = hitZone.contains(mouseScreenPoint)
        if inside != isCursorInsideNotch {
            isCursorInsideNotch = inside
            if inside {
                coordinator.handleHoverEntered()
            } else {
                coordinator.handleHoverExited()
            }
        }
    }

    public func close() {
        stopMouseHoverTracking()
        panel?.close()
        panel = nil
    }
}
