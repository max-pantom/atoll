// Mic and camera "in use" detection plus default-input mute. No permission needed: these only read whether a
// device is running somewhere, they never capture audio or video.
import Foundation
import CoreAudio
import CoreMediaIO

enum DeviceMonitor {
    /// True when any process is capturing from the default input device.
    static func micInUse() -> Bool {
        guard let dev = defaultInput() else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// True when any camera is streaming to some process.
    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == noErr else { return false }
        for dev in devices {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var got: UInt32 = 0
            let status = CMIOObjectGetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running)
            if status == noErr, running != 0 { return true }
        }
        return false
    }

    // MARK: Input mute

    private static func defaultInput() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    private static func address(_ selector: AudioObjectPropertySelector, element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    /// Channel elements to try: main (0), then the first two channels.
    private static let elements: [UInt32] = [0, 1, 2]

    private static func readU32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        for e in elements {
            var a = address(sel, element: e)
            guard AudioObjectHasProperty(dev, &a) else { continue }
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    private static func readF32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Float32? {
        for e in elements {
            var a = address(sel, element: e)
            guard AudioObjectHasProperty(dev, &a) else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    private static func write<T>(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: T) -> Bool {
        var wrote = false
        for e in elements {
            var a = address(sel, element: e)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(dev, &a),
                  AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { continue }
            var v = value
            if AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr { wrote = true }
            if e == 0 && wrote { break }
        }
        return wrote
    }

    /// Previous volume, kept so unmute restores it on devices without a mute switch.
    nonisolated(unsafe) private static var savedVolume: Float32 = 0.75

    static func isInputMuted() -> Bool {
        guard let dev = defaultInput() else { return false }
        if let m = readU32(dev, kAudioDevicePropertyMute) { return m != 0 }
        if let v = readF32(dev, kAudioDevicePropertyVolumeScalar) { return v <= 0.001 }
        return false
    }

    /// Mutes or unmutes the default input device; falls back to volume 0 when there is no mute switch.
    @discardableResult
    static func setInputMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultInput() else { return false }
        if readU32(dev, kAudioDevicePropertyMute) != nil, write(dev, kAudioDevicePropertyMute, UInt32(muted ? 1 : 0)) { return true }
        if let v = readF32(dev, kAudioDevicePropertyVolumeScalar) {
            if muted { if v > 0.001 { savedVolume = v } }
            return write(dev, kAudioDevicePropertyVolumeScalar, muted ? Float32(0) : max(savedVolume, 0.1))
        }
        return false
    }
}
