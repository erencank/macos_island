import CoreGraphics
import Darwin
import Foundation

public final class BrightnessControlService {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private var dlHandle: UnsafeMutableRawPointer?
    private var getBrightnessSymbol: GetBrightnessFn?
    private var setBrightnessSymbol: SetBrightnessFn?
    private var cachedBrightness: Float = 0.75

    public init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        if let handle = dlopen(path, RTLD_LAZY) {
            self.dlHandle = handle
            if let getSym = dlsym(handle, "DisplayServicesGetBrightness") {
                self.getBrightnessSymbol = unsafeBitCast(getSym, to: GetBrightnessFn.self)
            }
            if let setSym = dlsym(handle, "DisplayServicesSetBrightness") {
                self.setBrightnessSymbol = unsafeBitCast(setSym, to: SetBrightnessFn.self)
            }
        }
    }

    deinit {
        if let handle = dlHandle {
            dlclose(handle)
        }
    }

    public func currentBrightness(displayID: CGDirectDisplayID = CGMainDisplayID()) -> Float {
        guard let getFn = getBrightnessSymbol else {
            return cachedBrightness
        }
        var brightness: Float = cachedBrightness
        let status = getFn(displayID, &brightness)
        if status == 0 {
            cachedBrightness = max(0.0, min(1.0, brightness))
        }
        return cachedBrightness
    }

    @discardableResult
    public func setBrightness(_ value: Float, displayID: CGDirectDisplayID = CGMainDisplayID()) -> Float {
        let clamped = max(0.0, min(1.0, value))
        cachedBrightness = clamped
        if let setFn = setBrightnessSymbol {
            _ = setFn(displayID, clamped)
        }
        return clamped
    }

    public func stepBrightness(delta: Float, displayID: CGDirectDisplayID = CGMainDisplayID()) -> Float {
        let current = currentBrightness(displayID: displayID)
        return setBrightness(current + delta, displayID: displayID)
    }
}
