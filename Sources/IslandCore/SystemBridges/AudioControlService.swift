import AudioToolbox
import CoreAudio
import Foundation

public struct AudioControlService {
    public init() {}

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    public func currentVolume() -> Float {
        guard let deviceID = defaultOutputDeviceID() else { return 0.5 }
        var volume: Float32 = 0.5
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        if status != noErr {
            return 0.5
        }
        return max(0.0, min(1.0, volume))
    }

    public func isMuted() -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return false }
        return muted != 0
    }

    @discardableResult
    public func setVolume(_ newVolume: Float) -> Float {
        let clamped = max(0.0, min(1.0, newVolume))
        guard let deviceID = defaultOutputDeviceID() else { return clamped }

        // If setting volume > 0 while muted, unmute first
        if clamped > 0.001 && isMuted() {
            setMuted(false)
        }

        var volume: Float32 = clamped
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        if clamped <= 0.001 {
            setMuted(true)
        }
        return clamped
    }

    @discardableResult
    public func setMuted(_ mute: Bool) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return mute }
        var value: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        return mute
    }

    public func stepVolume(delta: Float) -> (volume: Float, isMuted: Bool) {
        let current = isMuted() ? 0.0 : currentVolume()
        let updated = setVolume(current + delta)
        return (updated, isMuted())
    }

    public func toggleMute() -> (volume: Float, isMuted: Bool) {
        let newMute = !isMuted()
        setMuted(newMute)
        return (newMute ? 0.0 : currentVolume(), newMute)
    }
}
