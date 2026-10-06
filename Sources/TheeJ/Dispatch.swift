import Foundation
#if canImport(AppKit)
import AppKit
#endif

let maxADC: Float32 = 1023.0

// ponytail: 1% deadzone ~= 10 ADC counts. Raise it if the pot still jitters at rest,
// lower it if the volume feels steppy. Cheap pots vary; this is the knob to turn.
let deadzone: Float32 = 0.01

func percent(_ scalar: Float32) -> Int {
    return min(100, max(0, Int(scalar * 100 + 0.5)))
}

var pendingBrightness: [Target: DispatchWorkItem] = [:]  // serial thread only, like lastApplied

func debounce(_ target: Target, on queue: DispatchQueue, after settle: Double, _ apply: @escaping () -> Void) {
    pendingBrightness[target]?.cancel()
    let work = DispatchWorkItem(block: apply)
    pendingBrightness[target] = work
    queue.asyncAfter(deadline: .now() + settle, execute: work)
}

// The previous version printed a retry line every 2 seconds while the device was missing, which
// grew the log to 1.2MB over one night. Log transitions only, never on a timer.
var lastLogged = ""
func log(_ message: String) {
    guard message != lastLogged else { return }
    lastLogged = message
    print(message)
}

var lastApplied: [Int: Float32] = [:]
var lastInvert = false  // serial thread only, like lastApplied
var lastPrint = Date.distantPast
let interactive = isatty(1) != 0

#if canImport(AppKit)
func handle(_ values: [Int]) {
    let config = shared.config()
    let mapping = config.setup.mapping
    let settle = config.setup.speed.settle
    // Flipped along with the knobs, or every knob would count as moved and jump to its mirror image.
    if config.setup.invert != lastInvert {
        lastApplied = lastApplied.mapValues { 1 - $0 }
        lastInvert = config.setup.invert
    }
    for (index, value) in values.enumerated() {
        let raw = Float32(value) / maxADC
        // This board's pots read 1023 at the bottom, so 1 - raw is the default and Invert undoes it.
        let unsnapped = config.setup.invert ? raw : 1 - raw
        // A pot often stops a count or two short of its rail, which would leave a light on at its
        // dimmest. Snapping also stops a knob resting by an end from flicking onto it as `extreme`.
        let scalar = unsnapped < deadzone ? 0 : unsnapped > 1 - deadzone ? 1 : unsnapped
        // Tracked, not applied: a knob that gains a job (on Apply, or as a calibration ends with every
        // knob parked at an end) waits to be moved instead of jumping there.
        guard !config.calibrating, let jobs = mapping[index] else {
            lastApplied[index] = scalar
            continue
        }
        // The first reading after open or reconnect is only a baseline, so nothing changes until a turn.
        guard let previous = lastApplied[index] else {
            lastApplied[index] = scalar
            continue
        }
        let extreme = scalar <= 0 || scalar >= 1
        guard scalar != previous, extreme || abs(scalar - previous) >= deadzone else { continue }
        lastApplied[index] = scalar

        // Every job of the knob takes its position. A display shows one HUD, the first job's that wants
        // it there: two would sit on top of each other.
        var shown: Set<CGDirectDisplayID> = []
        func once(on display: CGDirectDisplayID, _ show: () -> Void) {
            if shown.insert(display).inserted { show() }
        }
        // The volumes follow the knob. Everything else waits for Speed.settle, and the HUD tracks
        // the knob live, so the HUD is the only feedback during a turn. Do not debounce it.
        for target in jobs {
            switch target {
            case .master:
                setVolume(scalar)
                once(on: CGMainDisplayID()) { showOSD(osdVolumeImage, on: CGMainDisplayID(), scalar) }
            case .microphone:
                setVolume(scalar, input: true)
                once(on: CGMainDisplayID()) { showHUD(hudMicrophone, on: CGMainDisplayID(), scalar) }
            case .builtinBrightness:
                if let id = builtinDisplayID() {
                    // Main, not ddcQueue, so a stuck m1ddc can never hold the built-in up.
                    debounce(target, on: .main, after: settle) { setBuiltinBrightness(id, scalar) }
                    once(on: id) { showOSD(osdBrightnessImage, on: id, scalar) }
                }
            case .builtinContrast:
                if let id = builtinDisplayID() {
                    debounce(target, on: .main, after: settle) { _ = setDisplayContrast?(Float(scalar)) }
                    once(on: id) { showHUD(hudContrast, on: id, scalar) }
                }
            case .nightShift:
                debounce(target, on: .main, after: settle) { setNightShift(scalar) }
                once(on: CGMainDisplayID()) { showHUD(hudNightShift, on: CGMainDisplayID(), scalar) }
            case .brightness(let ordinal), .contrast(let ordinal):
                let externals = externalDisplays()
                if ordinal < externals.count {
                    let display = externals[ordinal]
                    let brightness = target == .brightness(ordinal)
                    debounce(target, on: ddcQueue, after: settle) {
                        if !writeDDC(display.uuid, brightness ? "luminance" : "contrast", percent(scalar)) {
                            fputs("\n\(title(target)) write failed. Is m1ddc installed?\n", stderr)
                        }
                    }
                    once(on: display.id) {
                        if brightness { showOSD(osdBrightnessImage, on: display.id, scalar) }
                        else { showHUD(hudContrast, on: display.id, scalar) }
                    }
                }
            case .builtinKeyboard:
                debounce(target, on: .main, after: settle) { setBuiltinKeyboard(scalar) }
                let display = builtinDisplayID() ?? CGMainDisplayID()
                once(on: display) { showOSD(osdKeyboardImage, on: display, scalar) }
            case .externalKeyboard:
                debounce(target, on: .main, after: settle) { setExternalKeyboard(scalar) }
                once(on: CGMainDisplayID()) { showOSD(osdKeyboardImage, on: CGMainDisplayID(), scalar) }
            case .zoom:
                debounce(target, on: .main, after: settle) { setZoom(scalar) }
                // The zoom spans every display, so its HUD goes where the eye is: the pointer's display.
                let display = pointerDisplayID()
                once(on: display) { showHUD(hudZoom, on: display, scalar) }
            case .app(let id):
                setAppVolume(id, scalar)
                once(on: CGMainDisplayID()) { showHUD(on: CGMainDisplayID(), scalar) { appIcon(id) } }
            }
        }
    }

    if config.calibrating {
        let now = ProcessInfo.processInfo.systemUptime  // taken here, before main queue latency
        DispatchQueue.main.async { menuBar?.feed(values, at: now) }
        return
    }

    let lines = ordered(mapping, by: config.setup.columns).flatMap { knob in
        knob.value.map { (text: "\(title($0)) \(percent(lastApplied[knob.key] ?? 0))%", target: $0) }
    }
    shared.setLines(lines)  // every line, so a job changed in Settings shows before the knob moves

    // Silent under launchd (no tty), so the log file doesn't grow forever.
    guard interactive, Date().timeIntervalSince(lastPrint) >= 0.5 else { return }
    lastPrint = Date()
    let cols = values.enumerated()
        .map { "\(mapping[$0.offset] != nil ? "*" : " ")\($0.offset):\(String(format: "%4d", $0.element))" }
        .joined()
    print("\r\(cols)   \(lines.map(\.text).joined(separator: "  "))  ", terminator: "")
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
#endif
