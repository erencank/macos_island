import AppKit
import Combine
import SwiftUI

/// Custom NSHostingView that dynamically calculates whether a mouse click falls inside
/// the active animated Notch silhouette. Everything outside the active notch silhouette
/// returns `nil` in `hitTest(_:)`, making the surrounding canvas 100% click-through.
public final class NotchHitTestHostingView<Content: View>: NSHostingView<Content> {
    public var activeHitRectProvider: (() -> CGRect)?

    private func currentInteractiveRect() -> CGRect {
        guard let provider = activeHitRectProvider else {
            return CGRect(x: bounds.midX - 100, y: bounds.maxY - 38, width: 200, height: 38)
        }
        return provider()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        let interactiveRect = currentInteractiveRect()
        guard interactiveRect.contains(localPoint) else {
            return nil
        }
        return super.hitTest(point)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Borderless, non-activating panel that sits above the macOS Menu Bar and Lock Screen
public final class NotchPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        // Sit above the status bar / menu bar and screen saver/lock screen overlays
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovable = false
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = false
    }

    public override var canBecomeKey: Bool {
        true
    }

    public override var canBecomeMain: Bool {
        false
    }
}
