import Foundation
import Darwin
import CoreAudio
import AppKit

let baud = speed_t(B9600)
let maxADC: Float32 = 1023.0
let sliderCount = 5

// ponytail: 1% deadzone ~= 10 ADC counts. Raise it if the pot still jitters at rest,
// lower it if the volume feels steppy. Cheap pots vary; this is the knob to turn.
let deadzone: Float32 = 0.01

// This board's pots read backwards: slider down = full volume. Flip to false if you rewire them.
let invertSliders = true

let args = Array(CommandLine.arguments.dropFirst())
let portOverride = args.first { $0.hasPrefix("/dev/") }
let sliderIndex = args.compactMap { Int($0) }.first ?? 0

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

// Shared between the serial thread and the menu bar on the main thread.
var menuBar: MenuBar?

final class Shared {
    private let lock = NSLock()
    private var connected = false
    private var port: String?
    private var volumePercent = 0
    private var reconnectFlag = false

    func snapshot() -> (connected: Bool, port: String?, volume: Int) {
        lock.lock(); defer { lock.unlock() }
        return (connected, port, volumePercent)
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

    func setVolume(_ percent: Int) {
        lock.lock(); volumePercent = percent; lock.unlock()
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

final class MenuBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let connectedIcon = makeIcon(slashed: false)
    private let disconnectedIcon = makeIcon(slashed: true)
    private let busyIcon = makeIcon(slashed: false, alpha: 0.38)

    override init() {
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
    }

    func refresh() {
        let state = shared.snapshot()
        item.button?.image = state.connected ? connectedIcon : disconnectedIcon
        item.button?.toolTip = state.connected
            ? "deej: \(state.port ?? "connected"), \(state.volume)%"
            : "deej: not connected"
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            reconnect()
        }
    }

    @objc private func reconnect() {
        item.button?.image = busyIcon  // brief, so a click never looks like it did nothing
        shared.requestReconnect()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Assigning item.menu makes the button open it instead of firing the action, so it is
    // attached only for this click and cleared straight afterwards.
    private func showMenu() {
        let state = shared.snapshot()
        let menu = NSMenu()
        let status = NSMenuItem(
            title: state.connected
                ? "Connected: \(state.port ?? "?")  \(state.volume)%"
                : "Not connected",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit deej", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil { entry.target = self }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}

var lastApplied: Float32 = -1
var lastPrint = Date.distantPast
let interactive = isatty(1) != 0

func handle(_ values: [Int]) {
    guard sliderIndex < values.count else { return }
    let raw = Float32(values[sliderIndex]) / maxADC
    let scalar = invertSliders ? 1 - raw : raw
    let extreme = scalar <= 0 || scalar >= 1
    if scalar != lastApplied && (extreme || abs(scalar - lastApplied) >= deadzone) {
        lastApplied = scalar
        setMasterVolume(scalar)
        shared.setVolume(Int((scalar * 100).rounded()))
    }
    // Silent under launchd (no tty), so the log file doesn't grow forever.
    guard interactive, Date().timeIntervalSince(lastPrint) >= 0.5 else { return }
    lastPrint = Date()
    let cols = values.enumerated()
        .map { "\($0.offset == sliderIndex ? "*" : " ")\($0.offset):\(String(format: "%4d", $0.element))" }
        .joined()
    print("\r\(cols)   volume \(String(format: "%3d", Int(lastApplied * 100)))%  ", terminator: "")
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
            shared.setConnected(false, port: nil)
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        // O_NONBLOCK to skip the DTR carrier wait, then back to blocking for the read loop.
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0, configureSerial(fd), fcntl(fd, F_SETFL, 0) == 0 else {
            if fd >= 0 { close(fd) }
            shared.setConnected(false, port: nil)
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        shared.setConnected(true, port: path)
        readUntilDrop(fd)
        close(fd)
        shared.setConnected(false, port: nil)
        lastApplied = -1
        Thread.sleep(forTimeInterval: 1)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
print("deej-mac: slider \(sliderIndex) controls macOS output volume")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
menuBar = MenuBar()
DispatchQueue.global(qos: .utility).async { serialLoop() }
app.run()
