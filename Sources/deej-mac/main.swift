import Foundation
import Darwin
import CoreAudio
import CoreGraphics
import ColorSync

let baud = speed_t(B9600)
let maxADC: Float32 = 1023.0
let sliderCount = 5

// ponytail: 1% deadzone ~= 10 ADC counts. Raise it if the pot still jitters at rest,
// lower it if the volume feels steppy. Cheap pots vary; this is the knob to turn.
let deadzone: Float32 = 0.01

// This board's pots read backwards: slider down = full volume. Flip to false if you rewire them.
let invertSliders = true

enum Target {
    case master
    // Index into the external displays sorted left to right, so 0 is the leftmost.
    case brightness(Int)
}

// Knob A -> master volume, knob B -> left monitor, knob C -> right monitor. The board is
// wired, not configured, so this lives in source rather than a config file. Edit and rebuild
// if you rewire. The built-in display is deliberately not a target.
let mapping: [Int: Target] = [0: .master, 3: .brightness(0), 2: .brightness(1)]

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

// Split out from displayUUIDs() so the ordering rule is testable without hardware. The
// built-in is dropped rather than sorted: it sits at a negative x on this machine, so
// leaving it in would silently make it "monitor 1".
func orderExternals(_ displays: [(uuid: String, x: CGFloat, builtin: Bool)]) -> [String] {
    displays.filter { !$0.builtin }.sorted { $0.x < $1.x }.map { $0.uuid }
}

// Re-read every write rather than cached with a reconfiguration callback: this is a handful
// of microseconds at a 250ms cadence, and it means unplugging or rearranging monitors just
// works with no callback machinery. m1ddc accepts these UUIDs directly.
func displayUUIDs() -> [String] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    let displays = ids[0..<Int(count)].compactMap { id -> (uuid: String, x: CGFloat, builtin: Bool)? in
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cf) as String? else { return nil }
        return (uuid, CGDisplayBounds(id).origin.x, CGDisplayIsBuiltin(id) != 0)
    }
    return orderExternals(displays)
}

func percent(_ scalar: Float32) -> Int {
    return min(100, max(0, Int(scalar * 100 + 0.5)))
}

// ponytail: 250ms between writes. One m1ddc call measures ~77ms and DDC/CI is slow in its
// own right, so a fast sweep drops intermediate positions instead of queueing them. Lower it
// if the knob feels laggy, raise it if the panel struggles to keep up.
let brightnessInterval = 0.25

let brightnessLock = NSLock()
var brightnessDesired: [Int: Int] = [:]

func requestBrightness(_ ordinal: Int, _ value: Int) {
    brightnessLock.lock()
    brightnessDesired[ordinal] = value
    brightnessLock.unlock()
}

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

// Never call this from the serial thread. Lines arrive every ~10ms and a write blocks for
// ~77ms, so doing it inline would back up the serial buffer and stall the volume knob too.
// handle() only records the wanted value; this thread applies whatever the newest one is.
func brightnessWorker() {
    // Worker-owned. Deliberately the value last requested, never a reading: these Dells
    // answer `get luminance` with 0, so comparing against hardware would rewrite forever.
    var applied: [Int: Int] = [:]
    var warned = false

    while true {
        Thread.sleep(forTimeInterval: brightnessInterval)

        brightnessLock.lock()
        let desired = brightnessDesired
        brightnessLock.unlock()

        let pending = desired.filter { applied[$0.key] != $0.value }.sorted { $0.key < $1.key }
        if pending.isEmpty { continue }

        let uuids = displayUUIDs()
        for (ordinal, value) in pending {
            guard ordinal < uuids.count else { continue }
            if writeBrightness(uuids[ordinal], value) {
                applied[ordinal] = value
                warned = false
            } else if !warned {
                // Warn once per outage, not several times a second. Unplugging a monitor
                // lands here, and so does m1ddc missing entirely.
                warned = true
                fputs("\nBrightness write failed (monitor \(ordinal + 1)). Is m1ddc installed?\n", stderr)
            }
        }
    }
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

var lastApplied: [Int: Float32] = [:]
var lastPrint = Date.distantPast
let interactive = isatty(1) != 0
// Under launchd stdout is a file, which Swift block-buffers; without this the connect
// messages never reach /tmp/deej-mac.log. The status line is tty-only so this stays quiet.
setvbuf(stdout, nil, _IOLBF, 0)

func describe(_ index: Int) -> String {
    let value = Int((lastApplied[index] ?? 0) * 100)
    switch mapping[index] {
    case .master: return "vol \(String(format: "%3d", value))%"
    case .brightness(let ordinal): return "mon\(ordinal + 1) \(String(format: "%3d", value))%"
    case nil: return ""
    }
}

func handle(_ values: [Int]) {
    for (index, target) in mapping {
        guard index < values.count else { continue }
        let raw = Float32(values[index]) / maxADC
        let scalar = invertSliders ? 1 - raw : raw
        let previous = lastApplied[index] ?? -1
        let extreme = scalar <= 0 || scalar >= 1
        guard scalar != previous, extreme || abs(scalar - previous) >= deadzone else { continue }
        lastApplied[index] = scalar

        switch target {
        case .master: setMasterVolume(scalar)
        case .brightness(let ordinal): requestBrightness(ordinal, percent(scalar))
        }
    }

    // Silent under launchd (no tty), so the log file doesn't grow forever.
    guard interactive, Date().timeIntervalSince(lastPrint) >= 0.5 else { return }
    lastPrint = Date()
    let cols = values.enumerated()
        .map { "\(mapping[$0.offset] != nil ? "*" : " ")\($0.offset):\(String(format: "%4d", $0.element))" }
        .joined()
    let summary = mapping.keys.sorted().map(describe).joined(separator: "  ")
    print("\r\(cols)   \(summary)  ", terminator: "")
    fflush(stdout)
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

// precondition, not assert: build.sh compiles with -O, which strips assert entirely.
if args.contains("--selftest") {
    precondition(percent(0) == 0)
    precondition(percent(1) == 100)
    precondition(percent(-0.5) == 0)
    precondition(percent(1.5) == 100)
    precondition(percent(0.355) == 36)
    precondition(percent(0.004) == 0)
    // The built-in sits at a negative x. It must be dropped, not sorted to the front.
    precondition(orderExternals([("R", 2560, false), ("BUILTIN", -1470, true), ("L", 0, false)])
        == ["L", "R"])
    precondition(orderExternals([("BUILTIN", 0, true)]).isEmpty)
    print("selftest ok")
    exit(0)
}

for index in mapping.keys.sorted() {
    switch mapping[index]! {
    case .master: print("deej-mac: slider \(index) controls macOS output volume")
    case .brightness(let ordinal):
        print("deej-mac: slider \(index) controls external monitor \(ordinal + 1) brightness")
    }
}
if m1ddcPath == nil {
    fputs("m1ddc not found, brightness control is disabled. brew install m1ddc\n", stderr)
}
Thread.detachNewThread(brightnessWorker)

while true {
    guard let path = findPort() else {
        print("Waiting for Arduino serial device...")
        sleep(2)
        continue
    }
    print("Connecting to \(path)...")
    // O_NONBLOCK to skip the DTR carrier wait, then back to blocking for the read loop.
    let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else { perror("open"); sleep(2); continue }
    guard configureSerial(fd), fcntl(fd, F_SETFL, 0) == 0 else {
        fputs("Could not configure \(path)\n", stderr)
        close(fd)
        sleep(2)
        continue
    }
    print("Connected.")
    var buffer = Data()
    var bytes = [UInt8](repeating: 0, count: 256)
    var connected = true
    while connected {
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
            connected = false
        }
    }
    close(fd)
    print("\nDisconnected. Retrying...")
    lastApplied.removeAll()
    sleep(1)
}
