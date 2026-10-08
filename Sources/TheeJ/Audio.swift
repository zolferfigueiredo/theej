#if canImport(AppKit)
import CoreAudio

// 'vmvc' is kAudioHardwareServiceDeviceProperty_VirtualMainVolume. Spelled as a FourCC so we
// don't drag in the deprecated AudioHardwareService* symbols. Unlike per-channel 'volm' it
// works on devices that expose no main volume element (e.g. some Bluetooth headsets).
let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663

func defaultDevice(input: Bool) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    guard status == noErr, dev != kAudioObjectUnknown else { return nil }
    return dev
}

func setScalar(_ dev: AudioDeviceID, _ scope: AudioObjectPropertyScope,
               _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: Float32) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element)
    guard AudioObjectHasProperty(dev, &addr) else { return false }
    var v = value
    return AudioObjectSetPropertyData(
        dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
}

func getScalar(_ dev: AudioDeviceID, _ scope: AudioObjectPropertyScope,
               _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Float32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    guard AudioObjectHasProperty(dev, &addr) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

// Where setVolume left it, read the same way.
func volume(input: Bool = false) -> Float32? {
    guard let dev = defaultDevice(input: input) else { return nil }
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    return getScalar(dev, scope, virtualMainVolume, 0) ?? getScalar(dev, scope, kAudioDevicePropertyVolumeScalar, 1)
}

private func muteAddress(input: Bool) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                               mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain)
}

func setMuted(_ muted: Bool, input: Bool = false) {
    guard let dev = defaultDevice(input: input) else { return }
    var addr = muteAddress(input: input)
    var value: UInt32 = muted ? 1 : 0
    if AudioObjectHasProperty(dev, &addr) {
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// Whether it is muted now, or nil for a device with no mute.
// ponytail: such a device, as some microphones, can't be muted from here; turning its volume down
// instead would need its level kept to come back to.
func toggleMute(input: Bool = false) -> Bool? {
    guard let dev = defaultDevice(input: input) else { return nil }
    var addr = muteAddress(input: input)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
    value = value == 0 ? 1 : 0
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value) == noErr ? value == 1 : nil
}

// Resolved per call so swapping device (headphones connecting) just works.
func setVolume(_ scalar: Float32, input: Bool = false) {
    guard let dev = defaultDevice(input: input) else { return }
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    if setScalar(dev, scope, virtualMainVolume, 0, scalar) { return }
    _ = setScalar(dev, scope, kAudioDevicePropertyVolumeScalar, 1, scalar)
    _ = setScalar(dev, scope, kAudioDevicePropertyVolumeScalar, 2, scalar)
}
#endif
