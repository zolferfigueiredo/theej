#if canImport(AppKit)
import AppKit

// The same XPC service and selector MonitorControl uses, taken from its binary. Private, so every
// call here is best effort: losing the HUD must never cost a volume or brightness change.
@objc protocol OSDUIHelperProtocol {
    func showImage(_ image: Int64, onDisplayID: UInt32, priority: UInt32, msecUntilFade: UInt32,
                   filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
}

// ponytail: the three tunables. 1, 3 and 11 are the long-standing BezelServices graphic ids: sun,
// speaker and keyboard backlight. There is none for a microphone, contrast, Night Shift, zoom or a
// profile switch, so those get TheeJ's own HUD with the SF Symbols below. totalChiclets sets the bar resolution: 100 fills
// smoothly on the modern slider style, 16 gives the classic segmented look.
let osdBrightnessImage: Int64 = 1
let osdVolumeImage: Int64 = 3
let osdKeyboardImage: Int64 = 11
let hudMicrophone = "mic.fill"
let hudContrast = "circle.lefthalf.filled"
let hudNightShift = "moon.fill"
let hudZoom = "plus.magnifyingglass"
let hudProfile = "slider.vertical.3"  // the General tab's, where profiles are edited

// A job's HUD graphic at a menu item's size, for a knob's menu and its list of jobs: the app's icon for
// an app, and for the sun, speaker and keyboard light that OSDUIHelper draws, the nearest SF Symbol. A
// menu draws a symbol in its text colour, but a label's text attachment draws it black whatever the
// appearance, so a label passes its colour as tint.
func jobIcon(_ target: Target, tint: NSColor? = nil) -> NSImage? {
    let name: String
    switch target {
    case .app: return menuIcon(target)
    case .master: name = "speaker.wave.3.fill"
    case .microphone: name = hudMicrophone
    case .builtinBrightness, .brightness: name = "sun.max.fill"
    case .builtinContrast, .contrast: name = hudContrast
    case .nightShift: name = hudNightShift
    case .builtinKeyboard, .externalKeyboard: name = "light.max"
    case .zoom: name = hudZoom
    }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil).map { squareIcon($0, tint: tint) }
}

// A symbol centred in the square an app's icon takes, so every option's name starts at the same place.
func squareIcon(_ symbol: NSImage, tint: NSColor?) -> NSImage {
    let fit = min(14 / symbol.size.width, 14 / symbol.size.height)
    let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { square in
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        symbol.draw(in: NSRect(x: square.midX - size.width / 2, y: square.midY - size.height / 2,
                               width: size.width, height: size.height))
        if let tint {
            tint.set()  // resolved as it draws, so a dynamic colour follows light and dark
            square.fill(using: .sourceAtop)
        }
        return true
    }
    icon.isTemplate = tint == nil
    return icon
}
let osdChiclets: UInt32 = 100
let osdFadeMsec: UInt32 = 1000

let osdLock = NSLock()
var osdConnection: NSXPCConnection?

func osdHelper() -> OSDUIHelperProtocol? {
    osdLock.lock()
    if osdConnection == nil {
        // Not .privileged: that option is for root-owned services and the connection is
        // invalidated on the spot for a normal user process, which silently kills the HUD.
        let conn = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
        // OSDUIHelper is launched on demand and exits when idle, so a dropped connection is
        // routine rather than an error. Clear it and let the next call build a fresh one.
        let forget = { osdLock.lock(); osdConnection = nil; osdLock.unlock() }
        conn.invalidationHandler = forget
        conn.interruptionHandler = forget
        conn.resume()
        osdConnection = conn
    }
    let conn = osdConnection
    osdLock.unlock()  // released before the proxy call, so an invalidation cannot block on us
    return conn?.remoteObjectProxyWithErrorHandler { _ in } as? OSDUIHelperProtocol
}

func showOSD(_ image: Int64, on displayID: CGDirectDisplayID, _ scalar: Float32) {
    let total = Float32(osdChiclets)
    let filled = UInt32(max(0, min(total, (scalar * total).rounded())))
    osdHelper()?.showImage(image, onDisplayID: UInt32(displayID), priority: 0x1f4,
                           msecUntilFade: osdFadeMsec,
                           filledChiclets: filled, totalChiclets: osdChiclets, locked: false)
    // Both squares sit in the same spot, and TheeJ's would hide this one until it faded.
    DispatchQueue.main.async { hudShown += 1; hud?.window.orderOut(nil) }
}

// OSDUIHelper only draws its own graphics, so the jobs it has none for draw its square themselves:
// the measurements BiHan Brightness took from it at 2x, with an SF Symbol for the graphic.
final class HUDView: NSView {
    var symbol: NSImage?
    var scalar: Float32 = 0
    var text: String?  // a profile's name, in the bar's place
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let text {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            text.draw(in: NSRect(x: 12, y: 162, width: 176, height: 24),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                       .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        } else {
            NSColor(white: 0, alpha: 0.25).setFill()
            NSRect(x: 21, y: 173, width: 159, height: 6).fill()
            hudInk.setFill()
            let pitch = 160 / CGFloat(osdChiclets)
            let filled = Int((scalar * Float32(osdChiclets)).rounded())
            if pitch >= 4 {
                for i in 0..<filled { NSRect(x: 21 + pitch * CGFloat(i), y: 173, width: pitch - 1, height: 6).fill() }
            } else {
                // One bar: chiclets this narrow, side by side, would show their antialiased edges as seams.
                NSRect(x: 21, y: 173, width: 159 * CGFloat(filled) / CGFloat(osdChiclets), height: 6).fill()
            }
        }
        guard let symbol else { return }
        let fit = min(96 / symbol.size.width, 96 / symbol.size.height)
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        symbol.draw(in: NSRect(x: 100 - size.width / 2, y: 87 - size.height / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

let hudInk = NSColor(white: 0.55, alpha: 1)
let hudSymbolStyle = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [hudInk]))
var hud: (window: NSWindow, view: HUDView)?  // main thread only, built on first use, once NSApp exists
var hudShown = 0  // bumped per show, so an older fade leaves a newer HUD alone

func makeHUD() -> (window: NSWindow, view: HUDView) {
    let view = HUDView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
    // Screen zoom leaves the cursor level alone, so the HUD stays where it is, at its own size, while a
    // knob zooms in. Seen on macOS 26: the screen saver and accessibility overlay levels zoom with the rest.
    window.level = NSWindow.Level(Int(CGWindowLevelForKey(.cursorWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.appearance = NSAppearance(named: .darkAqua)  // the dark square in light mode too
    let blur = NSVisualEffectView(frame: view.frame)
    blur.material = .hudWindow
    blur.state = .active  // the app is never active, and the default state would render the blur inactive
    blur.maskImage = NSImage(size: view.frame.size, flipped: false) {
        NSBezierPath(roundedRect: $0, xRadius: 18, yRadius: 18).fill()
        return true
    }
    blur.addSubview(view)
    window.contentView = blur
    return (window, view)
}

func showHUD(_ symbol: String, on displayID: CGDirectDisplayID, _ scalar: Float32, text: String? = nil) {
    showHUD(on: displayID, scalar, text: text) {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(hudSymbolStyle)
    }
}

// Called from the serial thread, like showOSD. The image is made on the main thread.
func showHUD(on displayID: CGDirectDisplayID, _ scalar: Float32, text: String? = nil, image: @escaping () -> NSImage?) {
    DispatchQueue.main.async {
        guard let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }) else { return }
        let (window, view) = hud ?? makeHUD()
        hud = (window, view)
        hudShown += 1
        let shown = hudShown
        view.symbol = image()
        view.scalar = scalar
        view.text = text
        view.needsDisplay = true
        window.setFrameOrigin(NSPoint(x: screen.frame.midX - 100, y: screen.frame.minY + 140))
        window.alphaValue = 1
        window.orderFrontRegardless()
        // Faded by hand: an animator() fade keeps running over a newer show.
        let fadeStart = Double(osdFadeMsec) / 1000
        for i in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeStart + 0.03 * Double(i)) {
                guard shown == hudShown else { return }
                window.alphaValue = 1 - CGFloat(i) / 10
                if i == 10 { window.orderOut(nil) }
            }
        }
    }
}
#endif
