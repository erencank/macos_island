import AppKit
import CoreGraphics
import Foundation

public enum InterceptedHardwareKey: Equatable, Sendable {
    case volumeUp(fineStep: Bool)
    case volumeDown(fineStep: Bool)
    case mute
    case brightnessUp(fineStep: Bool)
    case brightnessDown(fineStep: Bool)
}

public final class HIDEventTapService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public var interceptSoundKeys: Bool = true
    public var interceptBrightnessKeys: Bool = true
    public var onHardwareKeyTriggered: ((InterceptedHardwareKey) -> Void)?

    private static let nxSubtypeAuxControlButtons: Int16 = 8
    private static let nxKeyTypeSoundUp: Int32 = 0
    private static let nxKeyTypeSoundDown: Int32 = 1
    private static let nxKeyTypeBrightnessUp: Int32 = 2
    private static let nxKeyTypeBrightnessDown: Int32 = 3
    private static let nxKeyTypeMute: Int32 = 7
    private static let nxKeyTypeMuteAlt: Int32 = 10

    public init() {}

    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil else { return true }

        // Listen for NSSystemDefined (rawValue 14) which carries volume/brightness hardware keys
        let systemDefinedMask = CGEventMask(1 << 14)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let service = Unmanaged<HIDEventTapService>.fromOpaque(refcon).takeUnretainedValue()
            return service.handleCGEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefinedMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            IslandLogger.hud.warning("Could not create CGEventTap; Accessibility permission may not be granted yet")
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        IslandLogger.hud.info("Started HIDEventTapService for Volume & Brightness HUD replacement")
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        IslandLogger.hud.info("Stopped HIDEventTapService")
    }

    private func handleCGEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.nxSubtypeAuxControlButtons else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = UInt32(truncatingIfNeeded: nsEvent.data1)
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = (keyState == 0x0A)

        let flags = nsEvent.modifierFlags
        let fineStep = flags.contains(.option) && flags.contains(.shift)

        let isSoundKey = (keyCode == Self.nxKeyTypeSoundUp || keyCode == Self.nxKeyTypeSoundDown || keyCode == Self.nxKeyTypeMute || keyCode == Self.nxKeyTypeMuteAlt)
        let isBrightnessKey = (keyCode == Self.nxKeyTypeBrightnessUp || keyCode == Self.nxKeyTypeBrightnessDown)

        if isSoundKey && !interceptSoundKeys {
            return Unmanaged.passUnretained(event)
        }
        if isBrightnessKey && !interceptBrightnessKeys {
            return Unmanaged.passUnretained(event)
        }

        if isSoundKey || isBrightnessKey {
            if isKeyDown {
                let mappedKey: InterceptedHardwareKey?
                switch keyCode {
                case Self.nxKeyTypeSoundUp:
                    mappedKey = .volumeUp(fineStep: fineStep)
                case Self.nxKeyTypeSoundDown:
                    mappedKey = .volumeDown(fineStep: fineStep)
                case Self.nxKeyTypeMute, Self.nxKeyTypeMuteAlt:
                    mappedKey = .mute
                case Self.nxKeyTypeBrightnessUp:
                    mappedKey = .brightnessUp(fineStep: fineStep)
                case Self.nxKeyTypeBrightnessDown:
                    mappedKey = .brightnessDown(fineStep: fineStep)
                default:
                    mappedKey = nil
                }

                if let mappedKey {
                    DispatchQueue.main.async { [weak self] in
                        self?.onHardwareKeyTriggered?(mappedKey)
                    }
                }
            }
            // Swallow both keyDown and keyUp so macOS never shows the corner liquid-glass HUD
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
