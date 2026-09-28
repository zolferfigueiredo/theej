import Foundation
import Darwin
import CoreAudio
import CoreGraphics
import ColorSync
import AppKit

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

func writeBrightness(_ uuid: String, _ value: Int) -> Bool {
    guard let m1ddc = m1ddcPath else { return false }
    let task = Process()
// Write only, never read back: these Dells answer `get luminance` with 0.
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
    // Preformatted rather than raw values: there are three targets now and the menu wants the
    // same string the terminal prints, so it is built once where the values already are.
    private var summary = ""
    private var reconnectFlag = false

    func snapshot() -> (connected: Bool, port: String?, summary: String) {
        lock.lock(); defer { lock.unlock() }
        return (connected, port, summary)
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

    func setSummary(_ text: String) {
        lock.lock(); summary = text; lock.unlock()
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

// Drawn in code rather than shipped as an asset. isTemplate lets macOS handle light and dark
// menu bars, which is also why the disconnected slash cannot use colour: a template image is
// an alpha mask, so the gap around the slash has to be real transparency.
func makeIcon(slashed: Bool, alpha: CGFloat = 1.0) -> NSImage {
    let side: CGFloat = 18
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        let s = side / 24.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * s, y: (24 - y) * s)  // design space is y down, AppKit is y up
        }
        let ink = NSColor.black.withAlphaComponent(alpha)
        ink.setStroke()
        ink.setFill()

        let xs: [CGFloat] = [5, 12, 19]
        let tracks = NSBezierPath()
        tracks.lineWidth = 1.7 * s
        tracks.lineCapStyle = .round
        for x in xs {
            tracks.move(to: pt(x, 3.5))
            tracks.line(to: pt(x, 20.5))
        }
        tracks.stroke()

        let knobY: [CGFloat] = [8.1, 14.6, 6.6]
        let kw = 7.6 * s, kh = 3.4 * s
        for (i, x) in xs.enumerated() {
            let c = pt(x, knobY[i])
            let r = NSRect(x: c.x - kw / 2, y: c.y - kh / 2, width: kw, height: kh)
            NSBezierPath(roundedRect: r, xRadius: kh / 2, yRadius: kh / 2).fill()
        }

        if slashed {
            let a = pt(1.6, 22.4), b = pt(22.4, 1.6)
            let gap = NSBezierPath()
            gap.move(to: a); gap.line(to: b)
            gap.lineWidth = 5.4 * s
            gap.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            gap.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            let slash = NSBezierPath()
            slash.move(to: a); slash.line(to: b)
            slash.lineWidth = 2.8 * s
            slash.lineCapStyle = .round
            slash.stroke()
        }
        return true
    }
    image.isTemplate = true
    return image
}

final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let connectedIcon = makeIcon(slashed: false)
    private let disconnectedIcon = makeIcon(slashed: true)
    private let busyIcon = makeIcon(slashed: false, alpha: 0.38)
    private let statusEntry = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusEntry.isEnabled = false
        menu.addItem(statusEntry)
        menu.addItem(.separator())
        menu.addItem(entry("Reconnect", #selector(reconnect), ""))
        menu.addItem(.separator())
        menu.addItem(entry("Quit deej", #selector(quit), "q"))

        item.menu = menu  // assigned permanently, so left and right click both open it
        refresh()
    }

    private func entry(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.isEnabled = true
        return mi
    }

    // Rebuilt as the menu opens, so the status line is never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let state = shared.snapshot()
        statusEntry.title = state.connected
            ? "Connected: \(state.port ?? "?")   \(state.summary)"
            : "Not connected"
    }

    func refresh() {
        let state = shared.snapshot()
        item.button?.image = state.connected ? connectedIcon : disconnectedIcon
        item.button?.toolTip = state.connected
            ? "deej: \(state.port ?? "connected"), \(state.summary)"
            : "deej: not connected"
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
// grew /tmp/deej-mac.log to 1.2MB over one night. Log transitions only, never on a timer.
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

    let summary = orderedIndices.map(describe).joined(separator: "  ")
    if changed { shared.setSummary(summary) }

    // Silent under launchd (no tty), so the log file doesn't grow forever.
    guard interactive, Date().timeIntervalSince(lastPrint) >= 0.5 else { return }
    lastPrint = Date()
    let cols = values.enumerated()
        .map { "\(mapping[$0.offset] != nil ? "*" : " ")\($0.offset):\(String(format: "%4d", $0.element))" }
        .joined()
    print("\r\(cols)   \(summary)  ", terminator: "")
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
    print("selftest ok")
    exit(0)
}

setvbuf(stdout, nil, _IOLBF, 0)
for index in orderedIndices {
    switch mapping[index]! {
    case .master: print("deej-mac: slider \(index) controls macOS output volume")
    case .builtinBrightness:
        print("deej-mac: slider \(index) controls built-in display brightness")
    case .brightness(let ordinal):
        print("deej-mac: slider \(index) controls external monitor \(ordinal + 1) brightness")
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
    // A burst of movement lands as one write carrying the last value.
    var landed: [Int] = []
    for v in 1...3 { debounce(.brightness(0), on: ddcQueue) { landed.append(v) } }
    Thread.sleep(forTimeInterval: brightnessSettle * 2)
    ddcQueue.sync {}
    precondition(landed == [3])
