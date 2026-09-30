import AppKit

// There is no public API for the built-in panel on Apple Silicon. This is the same private symbol
// MonitorControl imports. Resolved once, and if it ever disappears the knob goes inert rather
// than taking the daemon with it.
typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias BrightnessChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

let displayServices: (set: SetBrightnessFn, changed: BrightnessChangedFn?)? = {
    let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    guard let handle = dlopen(path, RTLD_LAZY),
          let setSym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
    let changedSym = dlsym(handle, "DisplayServicesBrightnessChanged")
    return (unsafeBitCast(setSym, to: SetBrightnessFn.self),
            changedSym.map { unsafeBitCast($0, to: BrightnessChangedFn.self) })
}()

func setBuiltinBrightness(_ id: CGDirectDisplayID, _ scalar: Float32) {
    guard let services = displayServices, services.set(id, Float(scalar)) == 0 else { return }
    // Without this, Control Center and the menu bar slider keep showing a stale value.
    services.changed?(id, Double(scalar))
}

// The Accessibility "Display contrast" setting, 0 normal to 1 maximum, which external monitors
// ignore. Private, from SkyLight. The argument is a 32-bit Float, not a CGFloat.
typealias SetContrastFn = @convention(c) (Float) -> Int32

let setDisplayContrast: SetContrastFn? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let sym = dlsym(handle, "CGSSetDisplayContrast") else { return nil }
    return unsafeBitCast(sym, to: SetContrastFn.self)
}()
