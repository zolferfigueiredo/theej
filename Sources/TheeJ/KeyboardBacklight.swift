#if canImport(AppKit)
import AppKit
import IOKit.hid

// A QMK keyboard with VIA, over its raw HID interface. A vendor usage page needs no Input Monitoring
// permission, and the device is not seized, so VIA and Keychron Launcher still work alongside.
// ponytail: the first VIA keyboard found. Main thread only, as debounce(on: .main) runs it.
var viaKeyboard: IOHIDDevice?

func openVIAKeyboard() -> IOHIDDevice? {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
    guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first,
          IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
    return device
}

// Both VIA dialects, each ignored by a keyboard that speaks the other. Protocol 9 (older Keychron
// firmware) is [set value, rgblight brightness, value]; protocol 12 is [set value, RGB matrix
// channel, brightness, value]. Never the save command, so a replug brings back the keyboard's own
// level and its flash is never written.
func viaReports(_ scalar: Float32) -> [[UInt8]] {
    let value = UInt8((max(0, min(1, scalar)) * 255).rounded())
    return [[0x07, 0x80, value], [0x07, 0x03, 0x01, value]].map { $0 + [UInt8](repeating: 0, count: 32 - $0.count) }
}

func setExternalKeyboard(_ scalar: Float32) {
    // A handle from before an unplug fails, and the second pass opens the keyboard again.
    for _ in 0..<2 {
        if viaKeyboard == nil { viaKeyboard = openVIAKeyboard() }
        guard let device = viaKeyboard else { return }
        // Report ID 0, with no ID byte in the buffer: QMK's raw HID descriptor has none.
        if viaReports(scalar).allSatisfy({
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0, $0.count) == kIOReturnSuccess
        }) { return }
        viaKeyboard = nil
    }
}
#endif
