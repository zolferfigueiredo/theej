#if canImport(AppKit)
import CoreAudio
import Foundation

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

// Whether macOS can set the output's volume. Some USB DACs have none, and then TheeJ turns their sound
// down itself: setSoftVolume.
func hasVolume(_ dev: AudioDeviceID) -> Bool {
    [(virtualMainVolume, UInt32(0)), (kAudioDevicePropertyVolumeScalar, 1)].contains { selector, element in
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &addr) && AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }
}

// Where setVolume left it, read the same way.
func volume(input: Bool = false) -> Float32? {
    guard let dev = defaultDevice(input: input) else { return nil }
    if !input, !hasVolume(dev) { return softVolume() }
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
    } else if !input, !hasVolume(dev) {
        setSoftVolume(muted: muted)
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
    if !AudioObjectHasProperty(dev, &addr), !input, !hasVolume(dev) {
        let muted = !softMuted()
        setSoftVolume(muted: muted)
        return muted
    }
    guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
    value = value == 0 ? 1 : 0
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value) == noErr ? value == 1 : nil
}

// Resolved per call so swapping device (headphones connecting) just works.
func setVolume(_ scalar: Float32, input: Bool = false) {
    guard let dev = defaultDevice(input: input) else { return }
    if !input, !hasVolume(dev) { return setSoftVolume(scalar) }
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    if setScalar(dev, scope, virtualMainVolume, 0, scalar) { return }
    _ = setScalar(dev, scope, kAudioDevicePropertyVolumeScalar, 1, scalar)
    _ = setScalar(dev, scope, kAudioDevicePropertyVolumeScalar, 2, scalar)
}

// The Alert volume slider under Sound Effects in System Settings, which Core Audio has no property for.
// Standard Additions' command runs in TheeJ itself, so no Automation permission is asked. Main thread only,
// as NSAppleScript is, and about a hundredth of a second each.
func setAlertVolume(_ scalar: Float32) {
    NSAppleScript(source: "set volume alert volume \(percent(scalar))")?.executeAndReturnError(nil)
}
#endif
