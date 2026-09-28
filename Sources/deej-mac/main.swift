import Foundation
import Darwin
import CoreAudio
import CoreGraphics
import ColorSync
import AppKit
import IOKit.hid

let appName = "DeJota"
let appVersion = "1.1.0"

let baud = speed_t(B9600)
let maxADC: Float32 = 1023.0

// ponytail: 1% deadzone ~= 10 ADC counts. Raise it if the pot still jitters at rest,
// lower it if the volume feels steppy. Cheap pots vary; this is the knob to turn.
let deadzone: Float32 = 0.01

// This board's pots read backwards: slider down = full volume. Flip to false if you rewire them.
let invertSliders = true

// The case names are the JSON keys of saved knobs, so renaming one loses that knob's job.
enum Target: Hashable, Codable {
    case master
    case microphone
    case builtinBrightness
    case builtinContrast
    case nightShift
    // Index into the external displays sorted left to right, so 0 is the leftmost.
    case brightness(Int)
    case contrast(Int)
    case builtinKeyboard
    case externalKeyboard
}

// The array index is the letter on the box (A = 0). column is the serial field the knob arrives
// on, which calibration finds: nil until it has. A nil target means the knob does nothing.
struct Knob: Codable, Equatable {
    var column: Int?
    var target: Target?
}

// The domain is the bundle identifier, com.zolfer.dejota. A suite with that name is refused, since
// it is the app's own domain.
let prefs = UserDefaults.standard

// A loop, not Dictionary(uniqueKeysWithValues:), which traps on a duplicate column.
func targets(_ knobs: [Knob]) -> [Int: Target] {
    var result: [Int: Target] = [:]
    for knob in knobs {
        if let column = knob.column, let target = knob.target { result[column] = target }
    }
    return result
}

// The menu and the status line read as the volumes, the built-in display and Night Shift, externals
// left to right, then keyboards. That is not the order of the serial columns driving them, so it
// needs its own ordering. Monitors
// take two ranks each from 10, and activeDisplays() stops at 16, so a target kind below 10 or from
// 42 up cannot collide with one.
func rank(_ target: Target) -> Int {
    switch target {
    case .master: return 0
    case .microphone: return 1
    case .builtinBrightness: return 2
    case .builtinContrast: return 3
    case .nightShift: return 4
    case .brightness(let ordinal): return 10 + 2 * ordinal
    case .contrast(let ordinal): return 11 + 2 * ordinal
    case .builtinKeyboard: return 100
    case .externalKeyboard: return 101
    }
}

func ordered(_ mapping: [Int: Target]) -> [(key: Int, value: Target)] {
    mapping.sorted { (rank($0.value), $0.key) < (rank($1.value), $1.key) }
}

func title(_ target: Target?) -> String {
    switch target {
    case nil: return "Nothing"
    case .master?: return "Master volume"
    case .microphone?: return "Microphone volume"
    case .builtinBrightness?: return "Built-in display brightness"
    case .builtinContrast?: return "Built-in display contrast"
    case .nightShift?: return "Night Shift warmth"
    case .brightness(let ordinal)?: return "Monitor \(ordinal + 1) brightness"
    case .contrast(let ordinal)?: return "Monitor \(ordinal + 1) contrast"
    case .builtinKeyboard?: return "Built-in keyboard backlight"
    case .externalKeyboard?: return "External keyboard backlight"
    }
}

func letter(_ index: Int) -> String { String(Character(UnicodeScalar(UInt8(65 + index)))) }

let args = Array(CommandLine.arguments.dropFirst())
let portOverride = args.first { $0.hasPrefix("/dev/") }

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

// Resolved per call so swapping device (headphones connecting) just works.
func setVolume(_ scalar: Float32, input: Bool = false) {
    guard let dev = defaultDevice(input: input) else { return }
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    if setScalar(dev, scope, virtualMainVolume, 0, scalar) { return }
    _ = setScalar(dev, scope, kAudioDevicePropertyVolumeScalar, 1, scalar)
    _ = setScalar(dev, scope, kAudioDevicePropertyVolumeScalar, 2, scalar)
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

// MARK: - Built-in display

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

// MARK: - CoreBrightness

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
}

let blueLight = coreBrightness("CBBlueLightClient", BlueLightClient.self) as? BlueLightClient

// 0 switches it off without storing 0 as the warmth, so Control Center still turns it back on warm.
func setNightShift(_ scalar: Float32) {
    if scalar > 0 { _ = blueLight?.setStrength?(Float(scalar), commit: true) }
    _ = blueLight?.setEnabled?(scalar > 0)
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

// MARK: - External keyboard backlight

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

// MARK: - System HUD

// The same XPC service and selector MonitorControl uses, taken from its binary. Private, so every
// call here is best effort: losing the HUD must never cost a volume or brightness change.
@objc protocol OSDUIHelperProtocol {
    func showImage(_ image: Int64, onDisplayID: UInt32, priority: UInt32, msecUntilFade: UInt32,
                   filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
}

// ponytail: the three tunables. 1, 3 and 11 are the long-standing BezelServices graphic ids: sun,
// speaker and keyboard backlight. 0 has no graphic, so the HUD shows the bar alone, for targets macOS has no icon for.
// totalChiclets sets the bar resolution: 100 fills smoothly on the modern slider style, 16 gives
// the classic segmented look.
let osdBrightnessImage: Int64 = 1
let osdVolumeImage: Int64 = 3
let osdKeyboardImage: Int64 = 11
let osdBarImage: Int64 = 0
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

// ponytail: every job but the volumes applies once a knob has been still this long; each movement
// restarts the wait. It must stay well above ~110ms, the longest wiper dropout on this board (a
// moving pot briefly reads its neighbour's value), or a dropout reaches the panel as a flash.
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

// Write only, never read back: these Dells answer every `get` with 0.
func writeDDC(_ uuid: String, _ feature: String, _ value: Int) -> Bool {
    guard let m1ddc = m1ddcPath else { return false }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: m1ddc)
    task.arguments = ["display", uuid, "set", feature, String(value)]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}

// MARK: - Serial

// Reject anything that isn't all in-range integers rather than salvaging fields out of garbage.
// Any field count parses: the sketch decides it, and readUntilDrop checks that it holds steady.
func parse(_ line: String) -> [Int]? {
    var values: [Int] = []
    for field in line.split(separator: "|", omittingEmptySubsequences: false) {
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

// MARK: - Calibration

// Pure, so --selftest can drive it with fake lines and a fake clock. For each knob, phase 0 finds
// its column, 1 to 3 are the slow, fast and slow turns, and 4 is the sweeps.
struct Calibrator {
    static let turnSeconds = 20.0
    static let sweepsNeeded = 10

    private(set) var found: [Int?]
    private(set) var knob = 0
    private(set) var phase = 0
    private(set) var left = turnSeconds
    private(set) var sweeps = 0
    private var low: [Int] = []
    private var high: [Int] = []
    private var anchor = -1
    private var lastMove = -Double.infinity
    private var lastTime = 0.0
    private var armed = false

    init(knobs: Int) { found = Array(repeating: nil, count: knobs) }

    var done: Bool { knob >= found.count }

    mutating func feed(_ values: [Int], at now: Double) {
        guard !done else { return }
        if phase == 0 {
            if low.count != values.count { low = values; high = values }
            for (i, v) in values.enumerated() {
                low[i] = min(low[i], v)
                high[i] = max(high[i], v)
            }
            // The widest swing, not the first past the bar: a pin with no pot echoes the channel
            // read before it, so it moves with the knob.
            let taken = found
            let best = values.indices.filter { !taken.contains($0) }
                .max { high[$0] - low[$0] < high[$1] - low[$1] }
            if let best, high[best] - low[best] >= 512 {
                found[knob] = best
                next()
            }
            return
        }
        guard let column = found[knob], column < values.count else { return }
        let value = values[column]
        if phase < 4 {
            // Checked before lastMove moves on, so the gap of a reconnect never counts.
            if anchor < 0 { anchor = value }
            if now - lastMove <= 1 { left -= now - lastTime }
            if abs(value - anchor) >= 10 { anchor = value; lastMove = now }
            lastTime = now
            if left <= 0 { next() }
        } else {
            // ponytail: a stray reading at the far end can re-arm and count a sweep early. That only
            // shortens the cleaning; require a few readings at each end if it ever matters.
            if value <= 100 { armed = true } else if armed && value >= 923 { armed = false; sweeps += 1 }
            if sweeps >= Self.sweepsNeeded { next() }
        }
    }

    // Keeps anything already found, so skipping a new knob's turns still records its input.
    mutating func skip() {
        guard !done else { return }
        knob += 1
        reset(0)
    }

    private mutating func next() {
        if phase == 4 { knob += 1; reset(0) } else { reset(phase + 1) }
    }

    private mutating func reset(_ newPhase: Int) {
        phase = newPhase
        low = []
        high = []
        left = Self.turnSeconds
        sweeps = 0
        anchor = -1
        lastMove = -.infinity
        armed = false
    }
}

// A skipped knob keeps its old input unless this run found that input on another knob.
func calibrated(_ knobs: [Knob], found: [Int?]) -> [Knob] {
    let claimed = Set(found.compactMap { $0 })
    return knobs.enumerated().map { index, knob in
        var knob = knob
        if index < found.count, let column = found[index] {
            knob.column = column
        } else if let column = knob.column, claimed.contains(column) {
            knob.column = nil
        }
        return knob
    }
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
    private var knobs = prefs.string(forKey: "knobs")
        .flatMap { try? JSONDecoder().decode([Knob].self, from: Data($0.utf8)) } ?? []
    private var calibrating = false

    func snapshot() -> (connected: Bool, port: String?, lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (connected, port, lines)
    }

    func config() -> (knobs: [Knob], calibrating: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (knobs, calibrating)
    }

    // Stored as a JSON string rather than data so `defaults read com.zolfer.dejota` is readable.
    func setKnobs(_ value: [Knob]) {
        lock.lock(); knobs = value; lock.unlock()
        if let json = try? JSONEncoder().encode(value) {
            prefs.set(String(decoding: json, as: UTF8.self), forKey: "knobs")
        }
    }

    func setCalibrating(_ value: Bool) {
        lock.lock(); calibrating = value; lock.unlock()
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

final class MenuBar: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let connectedIcon = makeIcon(parked: false)
    private let disconnectedIcon = makeIcon(parked: true)
    private let busyIcon = makeIcon(parked: false, alpha: 0.38)
    private var aboutWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var draft: [Knob] = []
    private let knobRows = NSStackView()
    private let knobEdit = NSSegmentedControl()
    private let calibrateOnSave = NSButton(checkboxWithTitle: "Calibrate on save", target: nil, action: nil)
    private var calibrationWindow: NSWindow?
    private var calibrator: Calibrator?
    private let stepTitle = NSTextField(labelWithString: "")
    private let stepBody = NSTextField(wrappingLabelWithString: "")
    private let stepProgress = NSTextField(labelWithString: "")
    private let skipButton = NSButton(title: "", target: nil, action: nil)

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
        menu.addItem(entry("Settings", #selector(openSettings), ","))
        let calibrateItem = entry("Calibrate", #selector(calibrate), "")
        calibrateItem.isEnabled = state.connected && !shared.config().knobs.isEmpty
        menu.addItem(calibrateItem)
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

    private func makeWindow(_ title: String, _ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        fit(window)
        window.center()
        return window
    }

    // Keeps the top edge where it is: setContentSize keeps the bottom one, so the title bar would move.
    private func fit(_ window: NSWindow) {
        guard let size = window.contentView?.fittingSize else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // A menu bar app is never frontmost on its own, and activation can be refused once the user has
    // moved to another app (as by the end of a calibration), hence ordering front regardless.
    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // Same layout as BiHan Brightness's About window.
    @objc private func about() {
        if aboutWindow == nil {
            let name = NSTextField(labelWithString: appName)
            name.font = .boldSystemFont(ofSize: 16)
            let text = NSStackView(views: [name,
                                           credit("By", "Zolfer Figueiredo", "http://zolfer.com/"),
                                           credit("Inspired by", "deej", "https://github.com/omriharel/deej"),
                                           NSTextField(labelWithString: "Version \(appVersion)")])
            text.orientation = .vertical
            text.setCustomSpacing(12, after: name)
            let logo = NSImageView(image: makeAppIcon(side: 96))
            logo.widthAnchor.constraint(equalToConstant: 96).isActive = true
            logo.heightAnchor.constraint(equalToConstant: 96).isActive = true
            let row = NSStackView(views: [logo, text])
            row.spacing = 24
            row.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 24, right: 40)
            aboutWindow = makeWindow("", row)
        }
        present(aboutWindow!)
    }

    // Only the name is a link. The tooltip holds the URL, so hovering also shows where it goes.
    private func credit(_ prefix: String, _ name: String, _ url: String) -> NSStackView {
        let link = NSButton(title: name, target: self, action: #selector(openLink))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.toolTip = url
        let line = NSStackView(views: [NSTextField(labelWithString: prefix), link])
        line.spacing = 3
        line.alignment = .firstBaseline
        return line
    }

    @objc private func openLink(_ sender: NSButton) {
        if let url = sender.toolTip.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }

    // MARK: Settings

    // A second click keeps unsaved edits in an open window.
    @objc private func openSettings() {
        if settingsWindow?.isVisible != true {
            draft = shared.config().knobs
            calibrateOnSave.state = prefs.object(forKey: "calibrateOnSave") as? Bool == false ? .off : .on
        }
        showSettings()
    }

    // Laid out as a System Settings group. Built once; after that only the knob rows change.
    private func showSettings() {
        if let window = settingsWindow {
            reloadKnobs()
            fit(window)
        } else {
            let heading = NSTextField(labelWithString: "Knobs")
            heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            knobEdit.segmentCount = 2
            knobEdit.trackingMode = .momentary
            knobEdit.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a knob"),
                              forSegment: 0)
            knobEdit.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove the last knob"),
                              forSegment: 1)
            knobEdit.setToolTip("Add a knob", forSegment: 0)
            knobEdit.setToolTip("Remove the last knob", forSegment: 1)
            knobEdit.target = self
            knobEdit.action = #selector(editKnobs)
            let header = NSStackView()
            header.addView(heading, in: .leading)
            header.addView(knobEdit, in: .trailing)

            knobRows.orientation = .vertical
            knobRows.spacing = 0
            knobRows.alignment = .trailing  // separators are narrower than the rows, which insets them on the left
            let group = NSBox()
            group.boxType = .custom
            group.cornerRadius = 10
            group.borderColor = .separatorColor
            group.fillColor = .quaternarySystemFill
            group.addSubview(knobRows)
            knobRows.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                knobRows.topAnchor.constraint(equalTo: group.topAnchor),
                knobRows.bottomAnchor.constraint(equalTo: group.bottomAnchor),
                knobRows.leadingAnchor.constraint(equalTo: group.leadingAnchor),
                knobRows.trailingAnchor.constraint(equalTo: group.trailingAnchor),
                group.widthAnchor.constraint(equalToConstant: 420),
            ])

            let caption = NSTextField(labelWithString: "Choose what each knob does.")
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = .secondaryLabelColor
            let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
            save.keyEquivalent = "\r"
            let footer = NSStackView()
            footer.addView(calibrateOnSave, in: .leading)
            footer.addView(save, in: .trailing)

            let content = NSStackView(views: [header, group, caption, footer])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 8
            content.setCustomSpacing(20, after: caption)
            content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            content.setHuggingPriority(.defaultHigh, for: .horizontal)  // else fittingSize drops the right inset
            header.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            footer.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            reloadKnobs()
            settingsWindow = makeWindow("\(appName) Settings", content)
        }
        present(settingsWindow!)
    }

    // Rebuilt on every change, which keeps each popup's tag equal to its knob index.
    private func reloadKnobs() {
        let assigned = draft.compactMap { knob -> Int? in
            switch knob.target {
            case .brightness(let ordinal)?, .contrast(let ordinal)?: return ordinal + 1
            default: return nil
            }
        }.max() ?? 0
        // Includes an assigned monitor that is unplugged right now, so Save cannot drop it.
        let monitors: [Target?] = (0..<max(2, externalDisplays().count, assigned))
            .flatMap { [.brightness($0), .contrast($0)] }
        let choices: [Target?] = [nil, .master, .microphone, .builtinBrightness, .builtinContrast, .nightShift]
            + monitors + [.builtinKeyboard, .externalKeyboard]

        for view in knobRows.arrangedSubviews { view.removeFromSuperview() }
        for (index, knob) in draft.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                knobRows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: knobRows.widthAnchor, constant: -12).isActive = true
            }
            let popup = NSPopUpButton()
            popup.isBordered = false
            for choice in choices {
                popup.addItem(withTitle: title(choice))
                popup.lastItem?.representedObject = choice
            }
            popup.selectItem(at: choices.firstIndex(of: knob.target) ?? 0)
            popup.tag = index
            popup.target = self
            popup.action = #selector(pick)
            popup.setAccessibilityLabel("Knob \(letter(index))")
            let row = NSStackView()
            row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            row.addView(NSTextField(labelWithString: "Knob \(letter(index))"), in: .leading)
            if knob.column == nil {
                let warning = NSTextField(labelWithString: "Needs calibration")
                warning.textColor = .systemRed
                row.addView(warning, in: .leading)
            }
            row.addView(popup, in: .trailing)
            knobRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: knobRows.widthAnchor).isActive = true
        }
        if draft.isEmpty {
            let empty = NSTextField(labelWithString: "No knobs. Press + to add one.")
            empty.textColor = .secondaryLabelColor
            let row = NSStackView()
            row.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
            row.addView(empty, in: .center)
            knobRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: knobRows.widthAnchor).isActive = true
        }
        knobEdit.setEnabled(draft.count < 26, forSegment: 0)  // letters end at Z
        knobEdit.setEnabled(!draft.isEmpty, forSegment: 1)
    }

    @objc private func pick(_ sender: NSPopUpButton) {
        draft[sender.tag].target = sender.selectedItem?.representedObject as? Target
    }

    @objc private func editKnobs(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            if draft.count < 26 { draft.append(Knob(column: nil, target: nil)) }
        } else if !draft.isEmpty {
            draft.removeLast()
        }
        showSettings()
    }

    @objc private func saveSettings() {
        let calibrateNow = calibrateOnSave.state == .on
        prefs.set(calibrateNow, forKey: "calibrateOnSave")
        shared.setKnobs(draft)
        if calibrateNow && shared.snapshot().connected { calibrate() }
    }

    // MARK: Calibration

    // runModal only ever runs from here, a menu or button action. Inside a main queue block (feed)
    // it would stall every line queued behind it until the alert closed.
    @objc private func calibrate() {
        if let window = calibrationWindow, calibrator != nil {
            present(window)
            return
        }
        let count = shared.config().knobs.count
        guard count > 0 else { return }
        let turns = Int(Calibrator.turnSeconds)
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Calibrate knob A?" : "Calibrate knobs A to \(letter(count - 1))?"
        alert.informativeText = """
            This takes about \(count == 1 ? "a minute" : "\(count) minutes, one per knob"). For each \
            knob, you first move it from one end to the other so \(appName) can tell which one it is. \
            Then you turn it slowly, fast, and slowly again for \(turns) seconds each, and sweep it \
            \(Calibrator.sweepsNeeded) times. The timers only run while the knob turns.

            You can skip a knob, but please don't skip one that jumps around: turning it is what cleans it.

            Every knob holds still until you finish.
            """
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        calibrator = Calibrator(knobs: count)
        if calibrationWindow == nil {
            stepTitle.font = .boldSystemFont(ofSize: 16)
            stepBody.preferredMaxLayoutWidth = 360
            stepBody.widthAnchor.constraint(equalToConstant: 360).isActive = true
            stepProgress.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            stepProgress.textColor = .secondaryLabelColor
            let cancel = NSButton(title: "Cancel", target: nil, action: #selector(NSWindow.performClose(_:)))
            cancel.keyEquivalent = "\u{1b}"
            skipButton.target = self
            skipButton.action = #selector(skipKnob)
            let buttons = NSStackView()
            buttons.addView(cancel, in: .trailing)
            buttons.addView(skipButton, in: .trailing)
            let content = NSStackView(views: [stepTitle, stepBody, stepProgress, buttons])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 12
            content.setCustomSpacing(20, after: stepProgress)
            content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            content.setHuggingPriority(.defaultHigh, for: .horizontal)
            buttons.widthAnchor.constraint(equalTo: stepBody.widthAnchor).isActive = true
            let window = makeWindow("\(appName) Calibration", content)
            window.delegate = self
            cancel.target = window
            calibrationWindow = window
        }
        showStep()
        present(calibrationWindow!)
        shared.setCalibrating(true)
    }

    // handle() sends every line here while calibrating.
    func feed(_ values: [Int], at now: Double) {
        guard var run = calibrator else { return }
        let before = (run.knob, run.phase)
        run.feed(values, at: now)
        calibrator = run
        if run.done {
            finish()
        } else if (run.knob, run.phase) != before {
            NSSound(named: "Tink")?.play()  // the user is watching the knob, not the screen
            showStep()
        } else {
            stepProgress.stringValue = progress(run)
        }
    }

    private func showStep() {
        guard let run = calibrator, let window = calibrationWindow else { return }
        let name = letter(run.knob)
        let found = run.found[run.knob] == nil ? "" : "Found it. "
        stepTitle.stringValue = "Knob \(name), \(run.knob + 1) of \(run.found.count)"
        stepBody.stringValue = [
            "Move knob \(name) from one end to the other.",
            "\(found)Now turn it slowly, back and forth.",
            "Now turn it fast.",
            "Slowly again.",
            "Sweep it from one end to the other, \(Calibrator.sweepsNeeded) times.",
        ][run.phase]
        stepProgress.stringValue = progress(run)
        skipButton.title = "Skip knob \(name)"
        fit(window)
    }

    private func progress(_ run: Calibrator) -> String {
        switch run.phase {
        case 0: return "Waiting for knob \(letter(run.knob)) to move"
        case 4: return "Sweep \(run.sweeps) of \(Calibrator.sweepsNeeded)"
        default:
            let seconds = Int(run.left.rounded(.up))
            return seconds == 1 ? "1 second left" : "\(seconds) seconds left"
        }
    }

    @objc private func skipKnob() {
        calibrator?.skip()
        if calibrator?.done == true { finish() } else { showStep() }
    }

    // Saves before closing: windowWillClose throws the run away.
    private func finish() {
        guard let run = calibrator else { return }
        shared.setKnobs(calibrated(shared.config().knobs, found: run.found))
        calibrationWindow?.close()
        draft = shared.config().knobs
        showSettings()
    }

    // Every way out of a run ends here, Cancel and the close button included, so the knobs never
    // stay silenced. Only the calibration window has this delegate.
    func windowWillClose(_ notification: Notification) {
        calibrator = nil
        shared.setCalibrating(false)
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

func handle(_ values: [Int]) {
    let config = shared.config()
    let mapping = targets(config.knobs)
    for (index, value) in values.enumerated() {
        let raw = Float32(value) / maxADC
        let unsnapped = invertSliders ? 1 - raw : raw
        // A pot often stops a count or two short of its rail, which would leave a light on at its
        // dimmest. Snapping also stops a knob resting by an end from flicking onto it as `extreme`.
        let scalar = unsnapped < deadzone ? 0 : unsnapped > 1 - deadzone ? 1 : unsnapped
        // Tracked, not applied: a knob that gains a job (on Save, or as a calibration ends with every
        // knob parked at an end) waits to be moved instead of jumping there.
        guard !config.calibrating, let target = mapping[index] else {
            lastApplied[index] = scalar
            continue
        }
        let previous = lastApplied[index] ?? -1
        let extreme = scalar <= 0 || scalar >= 1
        guard scalar != previous, extreme || abs(scalar - previous) >= deadzone else { continue }
        lastApplied[index] = scalar

        // The volumes follow the knob. Everything else waits for brightnessSettle, and the HUD tracks
        // the knob live, so the HUD is the only feedback during a turn. Do not debounce it.
        switch target {
        case .master:
            setVolume(scalar)
            showOSD(osdVolumeImage, on: CGMainDisplayID(), scalar)
        case .microphone:
            setVolume(scalar, input: true)
            showOSD(osdBarImage, on: CGMainDisplayID(), scalar)
        case .builtinBrightness:
            if let id = builtinDisplayID() {
                // Main, not ddcQueue, so a stuck m1ddc can never hold the built-in up.
                debounce(target, on: .main) { setBuiltinBrightness(id, scalar) }
                showOSD(osdBrightnessImage, on: id, scalar)
            }
        case .builtinContrast:
            if let id = builtinDisplayID() {
                debounce(target, on: .main) { _ = setDisplayContrast?(Float(scalar)) }
                showOSD(osdBarImage, on: id, scalar)
            }
        case .nightShift:
            debounce(target, on: .main) { setNightShift(scalar) }
            showOSD(osdBarImage, on: CGMainDisplayID(), scalar)
        case .brightness(let ordinal), .contrast(let ordinal):
            let externals = externalDisplays()
            if ordinal < externals.count {
                let display = externals[ordinal]
                let brightness = target == .brightness(ordinal)
                debounce(target, on: ddcQueue) {
                    if !writeDDC(display.uuid, brightness ? "luminance" : "contrast", percent(scalar)) {
                        fputs("\n\(title(target)) write failed. Is m1ddc installed?\n", stderr)
                    }
                }
                showOSD(brightness ? osdBrightnessImage : osdBarImage, on: display.id, scalar)
            }
        case .builtinKeyboard:
            debounce(target, on: .main) { setBuiltinKeyboard(scalar) }
            showOSD(osdKeyboardImage, on: builtinDisplayID() ?? CGMainDisplayID(), scalar)
        case .externalKeyboard:
            debounce(target, on: .main) { setExternalKeyboard(scalar) }
            showOSD(osdKeyboardImage, on: CGMainDisplayID(), scalar)
        }
    }

    if config.calibrating {
        let now = ProcessInfo.processInfo.systemUptime  // taken here, before main queue latency
        DispatchQueue.main.async { menuBar?.feed(values, at: now) }
        return
    }

    let lines = ordered(mapping).map { "\(title($0.value)) \(percent(lastApplied[$0.key] ?? 0))%" }
    shared.setLines(lines)  // every line, so a job changed in Settings shows before the knob moves

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
    // Opening the port resets the Arduino, so the first line can be bootloader noise or half a line.
    // A line counts only when the one before it had as many fields, which drops that and any line
    // that lost a "|" (every column after it would shift).
    var width = 0
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
                    if values.count == width { handle(values) }
                    width = values.count
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
    // A knob with no job maps to nothing.
    let sample = [Knob(column: 0, target: .master), Knob(column: 3, target: .brightness(0)),
                  Knob(column: 2, target: .brightness(1)), Knob(column: 4, target: nil),
                  Knob(column: 1, target: .builtinBrightness)]
    precondition(targets(sample) == [0: .master, 1: .builtinBrightness, 3: .brightness(0), 2: .brightness(1)])
    // Menu order is volume, then the built-in, then externals left to right, which is not the
    // serial column order. The rank bands must stay distinct as target kinds are added.
    precondition(ordered(targets(sample)).map(\.key) == [0, 1, 3, 2])
    let every: [Target] = [.master, .microphone, .builtinBrightness, .builtinContrast, .nightShift]
        + (0..<16).flatMap { [.brightness($0), .contrast($0)] } + [.builtinKeyboard, .externalKeyboard]
    precondition(Set(every.map(rank)).count == every.count)
    precondition(try! JSONDecoder().decode([Target].self, from: JSONEncoder().encode(every)) == every)
    // Knobs saved before the newer targets existed still load.
    let saved = #"[{"target":{"master":{}},"column":0},{"target":{"brightness":{"_0":0}},"column":3},"#
        + #"{"target":{"brightness":{"_0":1}},"column":2},{"column":4},{"target":{"builtinBrightness":{}},"column":1}]"#
    precondition(try! JSONDecoder().decode([Knob].self, from: Data(saved.utf8)) == sample)
    precondition(viaReports(1).map { Array($0.prefix(4)) } == [[7, 0x80, 255, 0], [7, 3, 1, 255]])
    precondition(viaReports(0.1).allSatisfy { $0.count == 32 })
    precondition(parse("7|1023|0\r") == [7, 1023, 0])
    precondition(parse("7||0") == nil && parse("1024") == nil)
    // Calibration finds the knob that swings, times only while it turns, then counts sweeps.
    var run = Calibrator(knobs: 2)
    var clock = 0.0
    func tick(_ values: [Int]) { clock += 0.03; run.feed(values, at: clock) }
    tick([500, 500, 500])
    tick([520, 500, 100])
    precondition(run.phase == 0)  // column 2 has only swung 400
    tick([520, 500, 1000])
    precondition(run.found == [2, nil] && run.phase == 1)
    for _ in 0..<1000 { tick([520, 500, 1000]) }  // 30 seconds untouched
    precondition(run.phase == 1 && run.left == Calibrator.turnSeconds)
    var turning = 400
    while run.phase < 4 { turning = 1000 - turning; tick([520, 500, turning]) }
    precondition(abs(clock - 30 - 3 * Calibrator.turnSeconds) < 1)
    for _ in 0..<Calibrator.sweepsNeeded { tick([520, 500, 0]); tick([520, 500, 1023]) }
    precondition(run.knob == 1 && run.phase == 0)
    tick([520, 500, 0])
    tick([520, 500, 1023])
    precondition(run.phase == 0)  // column 2 is taken, so knob B cannot claim it
    run.skip()
    precondition(run.done && run.found == [2, nil])
    let before = [Knob(column: 0, target: .master), Knob(column: 2, target: nil),
                  Knob(column: 4, target: nil)]
    precondition(calibrated(before, found: [2, nil, nil]).map(\.column) == [2, nil, 4])
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
for (index, knob) in shared.config().knobs.enumerated() {
    let input = knob.column.map { "input \($0)" } ?? "not calibrated"
    print("\(appName): knob \(letter(index)), \(input): \(title(knob.target))")
}
if m1ddcPath == nil {
    fputs("m1ddc not found, external brightness and contrast are disabled. brew install m1ddc\n", stderr)
}
if displayServices == nil {
    fputs("DisplayServices unavailable, built-in brightness is disabled.\n", stderr)
}
if setDisplayContrast == nil {
    fputs("CGSSetDisplayContrast unavailable, built-in contrast is disabled.\n", stderr)
}
if blueLight == nil {
    fputs("CoreBrightness unavailable, Night Shift is disabled.\n", stderr)
}
if keyboardLight == nil {
    fputs("CoreBrightness unavailable, the built-in keyboard backlight is disabled.\n", stderr)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
menuBar = MenuBar()
DispatchQueue.global(qos: .utility).async { serialLoop() }
app.run()
