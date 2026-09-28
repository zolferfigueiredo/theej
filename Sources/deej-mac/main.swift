import Foundation
import Darwin
import CoreAudio
import CoreGraphics
import ColorSync
import AppKit

let appName = "DeJota"
let appVersion = "1.0.1"

let baud = speed_t(B9600)
let maxADC: Float32 = 1023.0
let sliderCount = 5

// ponytail: 1% deadzone ~= 10 ADC counts. Raise it if the pot still jitters at rest,
// lower it if the volume feels steppy. Cheap pots vary; this is the knob to turn.
let deadzone: Float32 = 0.01

// This board's pots read backwards: slider down = full volume. Flip to false if you rewire them.
let invertSliders = true

enum Target: Hashable {
    case master
    case builtinBrightness
    // Index into the external displays sorted left to right, so 0 is the leftmost.
    case brightness(Int)
}

// Knob A -> master volume, knob E -> built-in display, knob B -> left monitor, knob C -> right
// monitor. The board is wired, not configured, so this lives in source rather than a config file.
// Edit and rebuild if you rewire. Column 4 is unused.
let mapping: [Int: Target] = [
    0: .master,
    1: .builtinBrightness,
    3: .brightness(0),
    2: .brightness(1),
]

// The menu and the status line read as volume, then the built-in, then externals left to right.
// That is not the order of the serial columns driving them, so it needs its own ordering. The
// bands are spaced so a new target kind cannot collide with a monitor ordinal.
func rank(_ target: Target) -> Int {
    switch target {
    case .master: return 0
    case .builtinBrightness: return 1
    case .brightness(let ordinal): return 2 + ordinal
    }
}
let orderedIndices = mapping.sorted { rank($0.value) < rank($1.value) }.map { $0.key }

let args = Array(CommandLine.arguments.dropFirst())
let portOverride = args.first { $0.hasPrefix("/dev/") }

// 'vmvc' is kAudioHardwareServiceDeviceProperty_VirtualMainVolume. Spelled as a FourCC so we
// don't drag in the deprecated AudioHardwareService* symbols. Unlike per-channel 'volm' it
// works on devices that expose no main volume element (e.g. some Bluetooth headsets).
let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663

func defaultOutputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    guard status == noErr, dev != kAudioObjectUnknown else { return nil }
    return dev
}

func setScalar(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector,
               _ element: UInt32, _ value: Float32) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: element)
    guard AudioObjectHasProperty(dev, &addr) else { return false }
    var v = value
    return AudioObjectSetPropertyData(
        dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
}

// Resolved per call so swapping output device (headphones connecting) just works.
func setMasterVolume(_ scalar: Float32) {
    guard let dev = defaultOutputDevice() else { return }
    if setScalar(dev, virtualMainVolume, 0, scalar) { return }
    _ = setScalar(dev, kAudioDevicePropertyVolumeScalar, 1, scalar)
    _ = setScalar(dev, kAudioDevicePropertyVolumeScalar, 2, scalar)
}

// MARK: - Monitor brightness

// Absolute path because launchd does not put homebrew on PATH. The PATH lookup is only a
// courtesy for odd install locations.
func findM1ddc() -> String? {
    for path in ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
    where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    which.arguments = ["which", "m1ddc"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = FileHandle.nullDevice
    guard (try? which.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    which.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

let m1ddcPath = findM1ddc()

// The uuid is what m1ddc addresses a monitor by; the id is what the HUD needs to pick a screen.
struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let x: CGFloat
    let builtin: Bool
}

// Split out from activeDisplays() so the ordering rule is testable without hardware. The
// built-in is dropped rather than sorted: it sits at a negative x on this machine, so
// leaving it in would silently make it "monitor 1".
func orderExternals(_ displays: [Display]) -> [Display] {
    displays.filter { !$0.builtin }.sorted { $0.x < $1.x }
}

// Re-read on every use rather than cached with a reconfiguration callback: this is a handful
// of microseconds, and it means unplugging or rearranging monitors just works with no callback
// machinery.
func activeDisplays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    return ids[0..<Int(count)].compactMap { id -> Display? in
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cf) as String? else { return nil }
        return Display(id: id, uuid: uuid, x: CGDisplayBounds(id).origin.x,
                       builtin: CGDisplayIsBuiltin(id) != 0)
    }
}

func externalDisplays() -> [Display] { orderExternals(activeDisplays()) }

func builtinDisplayID() -> CGDirectDisplayID? { activeDisplays().first { $0.builtin }?.id }

// MARK: - Built-in display brightness

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

// MARK: - System HUD

// The same XPC service and selector MonitorControl uses, taken from its binary. Private, so every
// call here is best effort: losing the HUD must never cost a volume or brightness change.
@objc protocol OSDUIHelperProtocol {
    func showImage(_ image: Int64, onDisplayID: UInt32, priority: UInt32, msecUntilFade: UInt32,
                   filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
}

// ponytail: the three tunables. 1 and 3 are the long-standing BezelServices graphic ids, sun and
// speaker. totalChiclets sets the bar resolution: 100 fills smoothly on the modern slider style,
// 16 gives the classic segmented look.
let osdBrightnessImage: Int64 = 1
let osdVolumeImage: Int64 = 3
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
}

func percent(_ scalar: Float32) -> Int {
    return min(100, max(0, Int(scalar * 100 + 0.5)))
}

// ponytail: brightness applies once a knob has been still this long; each movement restarts the
// wait. It must stay well above ~110ms, the longest wiper dropout on this board (a moving pot
// briefly reads its neighbour's value), or a dropout reaches the panel as a flash.
let brightnessSettle = 0.3

// Serial so two DDC writes never overlap. A write blocks for ~77ms, so it must never run on the
// serial thread: lines would back up behind it and stall the volume knob too.
let ddcQueue = DispatchQueue(label: "dejota.ddc")

var pendingBrightness: [Target: DispatchWorkItem] = [:]  // serial thread only, like lastApplied

func debounce(_ target: Target, on queue: DispatchQueue, _ apply: @escaping () -> Void) {
    pendingBrightness[target]?.cancel()
    let work = DispatchWorkItem(block: apply)
    pendingBrightness[target] = work
    queue.asyncAfter(deadline: .now() + brightnessSettle, execute: work)
}

// Write only, never read back: these Dells answer `get luminance` with 0.
func writeBrightness(_ uuid: String, _ value: Int) -> Bool {
    guard let m1ddc = m1ddcPath else { return false }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: m1ddc)
    task.arguments = ["display", uuid, "set", "luminance", String(value)]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}

// MARK: - Serial

// Opening the port resets the Arduino, so the first line is bootloader noise. Reject anything
// that isn't exactly N in-range integers rather than salvaging fields out of garbage.
func parse(_ line: String) -> [Int]? {
    let fields = line.split(separator: "|", omittingEmptySubsequences: false)
    guard fields.count == sliderCount else { return nil }
    var values: [Int] = []
    values.reserveCapacity(sliderCount)
    for field in fields {
        guard let v = Int(field.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...1023).contains(v) else { return nil }
        values.append(v)
    }
    return values
}

func findPort() -> String? {
    if let override = portOverride { return override }
    let entries = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).sorted()
    let prefixes = ["cu.usbmodem", "cu.usbserial", "cu.SLAB_USBtoUART", "cu.wchusbserial"]
    for prefix in prefixes {
        if let name = entries.first(where: { $0.hasPrefix(prefix) }) { return "/dev/" + name }
    }
    return nil
}

func configureSerial(_ fd: Int32) -> Bool {
    var options = termios()
    guard tcgetattr(fd, &options) == 0 else { return false }
    cfmakeraw(&options)  // also sets VMIN=1, VTIME=0 for blocking reads
    cfsetispeed(&options, baud)
    cfsetospeed(&options, baud)
    options.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
    options.c_cflag &= ~tcflag_t(PARENB | CSTOPB)
    return tcsetattr(fd, TCSANOW, &options) == 0
}

// MARK: - Menu bar

// Shared between the serial thread and the menu bar on the main thread.
var menuBar: MenuBar?

final class Shared {
    private let lock = NSLock()
    private var connected = false
    private var port: String?
    // Preformatted, one per knob in menu order: the same strings the terminal prints.
    private var lines: [String] = []
    private var reconnectFlag = false

    func snapshot() -> (connected: Bool, port: String?, lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (connected, port, lines)
    }

    func setConnected(_ value: Bool, port newPort: String?) {
        lock.lock()
        let changed = (value != connected) || (newPort != port)
        connected = value
        port = newPort
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { menuBar?.refresh() }
    }

    func setLines(_ value: [String]) {
        lock.lock(); lines = value; lock.unlock()
    }

    func requestReconnect() {
        lock.lock(); reconnectFlag = true; lock.unlock()
    }

    func takeReconnect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = reconnectFlag
        reconnectFlag = false
        return value
    }
}

let shared = Shared()

// The one fader both icons draw, so the menu bar and the app icon cannot drift apart. Numbers are
// in a 24-unit design space, y down; `box` is where that square lands. Four marks either side, and
// the knob sits on one and hides it: mark 2 when connected, just above the middle, and the last
// mark when parked at the bottom. The sizes are tuned to stay crisp at 18pt on a Retina menu bar.
struct Fader {
    let rail: NSBezierPath, marks: [NSBezierPath], groove: NSBezierPath
    let knob: NSBezierPath, railGap: NSBezierPath

    init(parked: Bool, in box: NSRect) {
        let s = box.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: box.minX + x * s, y: box.maxY - y * s)
        }
        func rect(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            let c = pt(cx, cy)
            return NSRect(x: c.x - w * s / 2, y: c.y - h * s / 2, width: w * s, height: h * s)
        }
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ width: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: pt(x0, y0))
            path.line(to: pt(x1, y1))
            path.lineWidth = width * s
            path.lineCapStyle = .round
            return path
        }

        let rows: [CGFloat] = [4, 9.33, 14.67, 20]
        let knobY = parked ? rows[3] : rows[1]
        rail = line(12, 3.33, 12, 20.67, 2.67)
        // One path per mark: AppKit rasterises a thin many-part path differently on a 1x screen and
        // each mark comes out about a pixel short.
        marks = rows.filter { $0 != knobY }.flatMap { y in [line(6, y, 8, y, 1.33), line(16, y, 18, y, 1.33)] }
        groove = line(9.33, knobY, 14.67, knobY, 1.33)
        knob = NSBezierPath(roundedRect: rect(12, knobY, 10.67, 5.33), xRadius: 1.33 * s, yRadius: 1.33 * s)
        railGap = NSBezierPath(rect: rect(12, knobY, 3, 8))
    }
}

// Drawn in code rather than shipped as an asset. isTemplate lets macOS handle light and dark menu
// bars, which is also why the gaps around the knob cannot use colour: a template image is an alpha
// mask, so they have to be real transparency.
func makeIcon(parked: Bool, alpha: CGFloat = 1.0, side: CGFloat = 18) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { box in
        let fader = Fader(parked: parked, in: box)
        let ink = NSColor.black.withAlphaComponent(alpha)
        ink.setStroke()
        ink.setFill()
        fader.rail.stroke()
        fader.marks.forEach { $0.stroke() }
        let context = NSGraphicsContext.current
        context?.compositingOperation = .clear
        fader.railGap.fill()
        context?.compositingOperation = .sourceOver
        fader.knob.fill()
        context?.compositingOperation = .clear
        fader.groove.stroke()
        context?.compositingOperation = .sourceOver
        return true
    }
    image.isTemplate = true
    return image
}

// The same fader in the colours of the original artwork, on a dark tile laid out on Apple's icon
// grid: an 824 square with 185 corners on a 1024 canvas. build.sh bakes it into AppIcon.icns.
func makeAppIcon(side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { box in
        let tile = box.insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024)
        let corner = side * 185 / 1024
        NSGradient(starting: NSColor(white: 0.18, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))?
            .draw(in: NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner), angle: -90)

        let fader = Fader(parked: false, in: tile.insetBy(dx: tile.width * 0.14, dy: tile.width * 0.14))
        NSColor(white: 0.45, alpha: 1).setStroke()
        fader.rail.stroke()
        NSColor(white: 0.9, alpha: 1).setStroke()
        fader.marks.forEach { $0.stroke() }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
        shadow.shadowBlurRadius = side * 0.024
        shadow.set()
        NSColor(white: 0.94, alpha: 1).setFill()
        fader.knob.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0.35, alpha: 1).setStroke()
        fader.groove.stroke()
        return true
    }
}

final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let connectedIcon = makeIcon(parked: false)
    private let disconnectedIcon = makeIcon(parked: true)
    private let busyIcon = makeIcon(parked: false, alpha: 0.38)
    private var aboutWindow: NSWindow?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menuNeedsUpdate(menu)
        item.menu = menu  // assigned permanently, so left and right click both open it
        refresh()
    }

    private func entry(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.isEnabled = true
        return mi
    }

    // Rebuilt as the menu opens, so the status lines are never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let state = shared.snapshot()
        let status = state.connected ? ["Connected: \(state.port ?? "?")"] + state.lines : ["Not connected"]
        menu.removeAllItems()
        menu.addItem(entry("About \(appName)", #selector(about), ""))
        menu.addItem(.separator())
        for line in status {
            let mi = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(entry("Reconnect", #selector(reconnect), ""))
        menu.addItem(.separator())
        menu.addItem(entry("Quit", #selector(quit), "q"))
    }

    // No knob values here: this only runs when the connection changes, so they would be stale.
    func refresh() {
        let state = shared.snapshot()
        item.button?.image = state.connected ? connectedIcon : disconnectedIcon
        item.button?.toolTip = "\(appName): \(state.connected ? state.port ?? "connected" : "not connected")"
    }

    // Same layout as BiHan Brightness's About window.
    @objc private func about() {
        if aboutWindow == nil {
            let name = NSTextField(labelWithString: appName)
            name.font = .boldSystemFont(ofSize: 16)
            let text = NSStackView(views: [name,
                                           link("By Zolfer Figueiredo", "http://zolfer.com/"),
                                           link("Inspired by deej", "https://github.com/omriharel/deej"),
                                           NSTextField(labelWithString: "Version \(appVersion)")])
            text.orientation = .vertical
            text.setCustomSpacing(12, after: name)
            let logo = NSImageView(image: makeAppIcon(side: 96))
            logo.widthAnchor.constraint(equalToConstant: 96).isActive = true
            logo.heightAnchor.constraint(equalToConstant: 96).isActive = true
            let row = NSStackView(views: [logo, text])
            row.spacing = 24
            row.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 24, right: 40)
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.contentView = row
            window.setContentSize(row.fittingSize)
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        NSApp.activate()  // a menu bar app is never frontmost on its own
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    // The tooltip holds the URL, so hovering also shows where the link goes.
    private func link(_ title: String, _ url: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLink))
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.toolTip = url
        return button
    }

    @objc private func openLink(_ sender: NSButton) {
        if let url = sender.toolTip.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }

    @objc private func reconnect() {
        item.button?.image = busyIcon  // brief, so the click never looks like it did nothing
        shared.requestReconnect()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Dispatch

// The previous version printed a retry line every 2 seconds while the device was missing, which
// grew the log to 1.2MB over one night. Log transitions only, never on a timer.
var lastLogged = ""
func log(_ message: String) {
    guard message != lastLogged else { return }
    lastLogged = message
    print(message)
}

var lastApplied: [Int: Float32] = [:]
var lastPrint = Date.distantPast
let interactive = isatty(1) != 0

func describe(_ index: Int) -> String {
    let value = Int((lastApplied[index] ?? 0) * 100)
    switch mapping[index] {
    case .master: return "vol \(String(format: "%3d", value))%"
    case .builtinBrightness: return "mac \(String(format: "%3d", value))%"
    case .brightness(let ordinal): return "mon\(ordinal + 1) \(String(format: "%3d", value))%"
    case nil: return ""
    }
}

func handle(_ values: [Int]) {
    var changed = false
    for (index, target) in mapping {
        guard index < values.count else { continue }
        let raw = Float32(values[index]) / maxADC
        let scalar = invertSliders ? 1 - raw : raw
        let previous = lastApplied[index] ?? -1
        let extreme = scalar <= 0 || scalar >= 1
        guard scalar != previous, extreme || abs(scalar - previous) >= deadzone else { continue }
        lastApplied[index] = scalar
        changed = true

        // The HUD tracks the knob live while brightness waits for brightnessSettle, so the HUD
        // is the only feedback during a turn. Do not debounce it.
        switch target {
        case .master:
            setMasterVolume(scalar)
            showOSD(osdVolumeImage, on: CGMainDisplayID(), scalar)
        case .builtinBrightness:
            if let id = builtinDisplayID() {
                // Main, not ddcQueue, so a stuck m1ddc can never hold the built-in up.
                debounce(target, on: .main) { setBuiltinBrightness(id, scalar) }
                showOSD(osdBrightnessImage, on: id, scalar)
            }
        case .brightness(let ordinal):
            let externals = externalDisplays()
            if ordinal < externals.count {
                let display = externals[ordinal]
                debounce(target, on: ddcQueue) {
                    if !writeBrightness(display.uuid, percent(scalar)) {
                        fputs("\nBrightness write failed (monitor \(ordinal + 1)). Is m1ddc installed?\n", stderr)
                    }
                }
                showOSD(osdBrightnessImage, on: display.id, scalar)
            }
        }
    }

    let lines = orderedIndices.map(describe)
    if changed { shared.setLines(lines) }

    // Silent under launchd (no tty), so the log file doesn't grow forever.
    guard interactive, Date().timeIntervalSince(lastPrint) >= 0.5 else { return }
    lastPrint = Date()
    let cols = values.enumerated()
        .map { "\(mapping[$0.offset] != nil ? "*" : " ")\($0.offset):\(String(format: "%4d", $0.element))" }
        .joined()
    print("\r\(cols)   \(lines.joined(separator: "  "))  ", terminator: "")
    fflush(stdout)
}

// poll() with a short timeout rather than a bare blocking read, so a reconnect click is noticed
// within 250ms. Closing the fd from the main thread to break a blocking read would race on fd reuse.
func readUntilDrop(_ fd: Int32) {
    var buffer = Data()
    var bytes = [UInt8](repeating: 0, count: 256)
    let problems = Int16(POLLHUP | POLLERR | POLLNVAL)
    while true {
        if shared.takeReconnect() { return }
        var watch = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&watch, 1, 250)
        if ready < 0 {
            if errno == EINTR { continue }
            return
        }
        if ready == 0 { continue }
        if watch.revents & problems != 0 { return }
        let count = read(fd, &bytes, bytes.count)
        if count > 0 {
            buffer.append(contentsOf: bytes[0..<count])
            while let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8), let values = parse(line) {
                    handle(values)
                }
            }
            if buffer.count > 1024 { buffer.removeAll() }  // no newline in sight: resync
        } else if count < 0 && errno == EINTR {
            continue
        } else {
            return
        }
    }
}

func serialLoop() {
    while true {
        guard let path = findPort() else {
            log("Waiting for a serial device")
            shared.setConnected(false, port: nil)
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        // O_NONBLOCK to skip the DTR carrier wait, then back to blocking for the read loop.
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0, configureSerial(fd), fcntl(fd, F_SETFL, 0) == 0 else {
            if fd >= 0 { close(fd) }
            log("Could not open \(path)")
            shared.setConnected(false, port: nil)
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        log("Connected: \(path)")
        shared.setConnected(true, port: path)
        readUntilDrop(fd)
        close(fd)
        log("Disconnected")
        shared.setConnected(false, port: nil)
        lastApplied.removeAll()
        Thread.sleep(forTimeInterval: 1)
    }
}

// MARK: - Start

// build.sh runs this to render the app icon at every size an .iconset needs, then iconutil packs it.
if let flag = args.firstIndex(of: "--iconset"), flag + 1 < args.count {
    let dir = URL(fileURLWithPath: args[flag + 1])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            makeAppIcon(side: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        }
    }
    exit(0)
}

// precondition, not assert: build.sh compiles with -O, which strips assert entirely.
if args.contains("--selftest") {
    precondition(percent(0) == 0)
    precondition(percent(1) == 100)
    precondition(percent(-0.5) == 0)
    precondition(percent(1.5) == 100)
    precondition(percent(0.355) == 36)
    precondition(percent(0.004) == 0)
    // The built-in sits at a negative x. It must be dropped, not sorted to the front.
    let fake = { (uuid: String, x: CGFloat, builtin: Bool) in
        Display(id: 0, uuid: uuid, x: x, builtin: builtin)
    }
    precondition(orderExternals([fake("R", 2560, false), fake("BUILTIN", -1470, true),
                                 fake("L", 0, false)]).map(\.uuid) == ["L", "R"])
    precondition(orderExternals([fake("BUILTIN", 0, true)]).isEmpty)
    // Menu order is volume, then the built-in, then externals left to right, which is not the
    // serial column order. The rank bands must stay distinct as target kinds are added.
    precondition(orderedIndices == [0, 1, 3, 2])
    precondition(Set([rank(.master), rank(.builtinBrightness),
                      rank(.brightness(0)), rank(.brightness(1))]).count == 4)
    // A burst of movement lands as one write carrying the last value.
    var landed: [Int] = []
    for v in 1...3 { debounce(.brightness(0), on: ddcQueue) { landed.append(v) } }
    Thread.sleep(forTimeInterval: brightnessSettle * 2)
    ddcQueue.sync {}
    precondition(landed == [3])
    print("selftest ok")
    exit(0)
}

setvbuf(stdout, nil, _IOLBF, 0)
for index in orderedIndices {
    switch mapping[index]! {
    case .master: print("\(appName): slider \(index) controls macOS output volume")
    case .builtinBrightness:
        print("\(appName): slider \(index) controls built-in display brightness")
    case .brightness(let ordinal):
        print("\(appName): slider \(index) controls external monitor \(ordinal + 1) brightness")
    }
}
if m1ddcPath == nil {
    fputs("m1ddc not found, external brightness is disabled. brew install m1ddc\n", stderr)
}
if displayServices == nil {
    fputs("DisplayServices unavailable, built-in brightness is disabled.\n", stderr)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
menuBar = MenuBar()
DispatchQueue.global(qos: .utility).async { serialLoop() }
app.run()
