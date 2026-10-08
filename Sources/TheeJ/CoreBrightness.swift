#if canImport(AppKit)
import AppKit

// No headers. Each protocol names the selectors, class_addProtocol lets a plain `as?` reach the
// class, and `optional` makes each call check respondsToSelector, so a selector that disappears
// leaves the knob inert instead of crashing the daemon.
func coreBrightness(_ name: String, _ proto: Protocol) -> NSObject? {
    _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
    guard let type = NSClassFromString(name) as? NSObject.Type else { return nil }
    _ = class_addProtocol(type, proto)
    return type.init()
}

@objc protocol BlueLightClient {
    @objc(setStrength:commit:) optional func setStrength(_ strength: Float, commit: Bool) -> Bool
    @objc(setEnabled:) optional func setEnabled(_ enabled: Bool) -> Bool
    @objc(getBlueLightStatus:) optional func getBlueLightStatus(_ status: UnsafeMutableRawPointer) -> Bool
}

let blueLight = coreBrightness("CBBlueLightClient", BlueLightClient.self) as? BlueLightClient

// 0 switches it off without storing 0 as the warmth, so Control Center still turns it back on warm.
func setNightShift(_ scalar: Float32) {
    if scalar > 0 { _ = blueLight?.setStrength?(Float(scalar), commit: true) }
    _ = blueLight?.setEnabled?(scalar > 0)
}

// Night Shift on or off, as Control Center turns it. The status is a private struct whose second byte
// says whether it is on; 64 bytes is more than it has ever taken. Whether it is on now, or nil.
func toggleNightShift() -> Bool? {
    var status = [UInt8](repeating: 0, count: 64)
    guard status.withUnsafeMutableBytes({ blueLight?.getBlueLightStatus?($0.baseAddress!) }) == true else { return nil }
    let on = status[1] == 0
    _ = blueLight?.setEnabled?(on)
    return on
}

@objc protocol KeyboardClient {
    @objc(copyKeyboardBacklightIDs) optional func copyKeyboardBacklightIDs() -> NSArray?
    @objc(setBrightness:fadeSpeed:commit:forKeyboard:)
    optional func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool, forKeyboard id: UInt64) -> Bool
}

let keyboardLight = coreBrightness("KeyboardBrightnessClient", KeyboardClient.self) as? KeyboardClient

// This setter, not setBrightness:forKeyboard:, is the one seen to light it on macOS 26. 0 mutes it
// and anything above unmutes it. macOS still turns it off when idle or in bright light, and brings
// it back at this level.
func setBuiltinKeyboard(_ scalar: Float32) {
    guard let id = (keyboardLight?.copyKeyboardBacklightIDs?()?.firstObject as? NSNumber)?.uint64Value
    else { return }
    _ = keyboardLight?.setBrightness?(Float(scalar), fadeSpeed: 0, commit: true, forKeyboard: id)
}
#endif
