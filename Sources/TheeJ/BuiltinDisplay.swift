#if canImport(AppKit)
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

// Screen zoom, set in WindowServer with the call Accessibility Zoom itself makes. Zoom can't be told a
// level from outside (it zooms only from its own keys, scrolling and gestures), and it doesn't know about
// this zoom, so TheeJ follows the pointer itself. Private, from SkyLight, taken apart on macOS 26. The
// origin is the point drawn at the middle of every display taken as one picture, and WindowServer keeps
// the view inside them. The last three are Zoom's interpolate, warpCursor and velocity. Moving the view
// keeps the pointer where it is on the glass, so the point under it changes; warpCursor keeps that point
// instead and moves the pointer. The zoom outlasts TheeJ, so quitting zooms back out.
typealias SetZoomFn = @convention(c) (Int32, UnsafePointer<CGPoint>?, Double, Int32, Int32, Double) -> Int32

let zoomServices: (connection: Int32, set: SetZoomFn)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let connection = dlsym(handle, "CGSMainConnectionID"),
          let set = dlsym(handle, "CGSSetZoomParameters") else { return nil }
    return (unsafeBitCast(connection, to: (@convention(c) () -> Int32).self)(), unsafeBitCast(set, to: SetZoomFn.self))
}()

// ponytail: 1x at the bottom of the knob to maxZoom at the top, on a curve, so the first half of the
// knob covers 1x to about 3x. Accessibility Zoom goes up to 40x if this is too little.
let maxZoom = 10.0
var zoomTracker: Timer?  // main thread only, as debounce(on: .main) runs setZoom; set while zoomed in

func setZoom(_ scalar: Float32) {
    guard let zoom = zoomServices else { return }
    zoomTracker?.invalidate()
    zoomTracker = nil
    let factor = pow(maxZoom, Double(scalar))
    guard factor > 1 else {
        _ = zoom.set(zoom.connection, nil, 1, 0, 0, 0)
        return
    }
    // ponytail: polls the pointer 60 times a second while zoomed in, which needs no permission, where
    // a global mouse monitor would miss the moves over TheeJ's own windows. The view follows it as Zoom's
    // "continuously with pointer" does: the pointer sits as far across the glass as the point under it is
    // across the desktop, so the view is still while the pointer is. Setting the origin to the pointer
    // instead chases it into a corner. Displays added while zoomed in count from the knob's next move.
    let desktop = activeDisplays().map { CGDisplayBounds($0.id) }.reduce(CGRect.null) { $0.union($1) }
    var followed: CGPoint?
    let follow = {
        guard let pointer = CGEvent(source: nil)?.location, pointer != followed else { return }
        followed = pointer
        var origin = CGPoint(x: desktop.midX + (pointer.x - desktop.midX) * (1 - 1 / factor),
                             y: desktop.midY + (pointer.y - desktop.midY) * (1 - 1 / factor))
        _ = zoom.set(zoom.connection, &origin, factor, 0, 1, 0)
    }
    follow()
    zoomTracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in follow() }
}
#endif
