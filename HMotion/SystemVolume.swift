import AudioToolbox
import CoreAudio
import Foundation

/// Reads and writes the system-wide output volume — the same slider the volume keys drive.
///
/// Uses the default output device's *virtual main volume*, which is the aggregate
/// control CoreAudio exposes for devices whose channels are managed individually.
nonisolated enum SystemVolume {

    /// The output device currently selected in Sound preferences.
    private static var defaultOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Current output volume in `0...1`, or `nil` if the device has no settable main volume.
    static func currentVolume() -> Float? {
        guard let device = defaultOutputDevice else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Float(volume)
    }

    @discardableResult
    static func setVolume(_ volume: Float) -> Bool {
        guard let device = defaultOutputDevice else { return false }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }

        var value = Float32(min(max(volume, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
