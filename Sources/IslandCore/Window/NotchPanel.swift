import AppKit
import Combine
import SwiftUI

/// Custom NSHostingView that dynamically calculates whether a mouse click falls inside
/// the active animated Notch silhouette. Everything outside the active notch silhouette
/// returns `nil` in `hitTest(_:)`, making the surrounding canvas 100% click-through.
public final class NotchHitTestHostingView<Content: View>: NSHostingView<Content> {
    public var activeHitRectProvider: (() -> CGRect)?
    public var onFileDragEntered: (() -> Void)?
    public var onFileDragExited: (() -> Void)?
    public var onFilesDropped: (([URL]) -> Bool)?

    public required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func currentInteractiveRect() -> CGRect {
        guard let provider = activeHitRectProvider else {
            return CGRect(x: bounds.midX - 100, y: 0, width: 200, height: 38)
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

    // MARK: - NSDraggingDestination

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.extractFileURLs(from: sender.draggingPasteboard).isEmpty == false else {
            return []
        }
        onFileDragEntered?()
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.extractFileURLs(from: sender.draggingPasteboard).isEmpty == false else {
            return []
        }
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragExited?()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.extractFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return onFilesDropped?(urls) ?? false
    }

    public static func extractFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (pasteboard.readObjects(forClasses: classes, options: options) as? [URL]) ?? []
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

    public var allowsKeyFocus: Bool = true

    public override var canBecomeKey: Bool {
        allowsKeyFocus
    }

    public override var canBecomeMain: Bool {
        false
    }
}
