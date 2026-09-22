import Foundation
import Darwin
import CoreAudio

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

// 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume. Spelled as a FourCC so we
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

var lastApplied: Float32 = -1
var lastPrint = Date.distantPast
let interactive = isatty(1) != 0
// Under launchd stdout is a file, which Swift block-buffers; without this the connect
// messages never reach /tmp/deej-mac.log. The status line is tty-only so this stays quiet.
setvbuf(stdout, nil, _IOLBF, 0)

func handle(_ values: [Int]) {
    guard sliderIndex < values.count else { return }
    let raw = Float32(values[sliderIndex]) / maxADC
    let scalar = invertSliders ? 1 - raw : raw
    let extreme = scalar <= 0 || scalar >= 1
    if scalar != lastApplied && (extreme || abs(scalar - lastApplied) >= deadzone) {
        lastApplied = scalar
        setMasterVolume(scalar)
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

print("deej-mac: slider \(sliderIndex) controls macOS output volume")

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
    lastApplied = -1
    sleep(1)
}
