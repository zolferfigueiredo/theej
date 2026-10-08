import Foundation
#if canImport(AppKit)
import AppKit
#endif

// ponytail: 1% deadzone ~= 10 ADC counts. Raise it if the pot still jitters at rest,
// lower it if the volume feels steppy. Cheap pots vary; this is the knob to turn.
let deadzone: Float32 = 0.01

func percent(_ scalar: Float32) -> Int {
    return min(100, max(0, Int(scalar * 100 + 0.5)))
}

var pendingBrightness: [Target: DispatchWorkItem] = [:]  // engine queue only, like boardStates

func debounce(_ target: Target, on queue: DispatchQueue, after settle: Double, _ apply: @escaping () -> Void) {
    pendingBrightness[target]?.cancel()
    let work = DispatchWorkItem(block: apply)
    pendingBrightness[target] = work
    queue.asyncAfter(deadline: .now() + settle, execute: work)
}

// The previous version printed a retry line every 2 seconds while the device was missing, which
// grew the log to 1.2MB over one night. Log transitions only, never on a timer.
private let logLock = NSLock()
private var lastLogged: [String: String] = [:]
func log(_ message: String, for board: String = "") {
    logLock.lock()
    defer { logLock.unlock() }
    guard lastLogged[board] != message else { return }
    lastLogged[board] = message
    print(board.isEmpty ? message : "\(board): \(message)")
}

let interactive = isatty(1) != 0

#if canImport(AppKit)
// ponytail: one queue for every board. handle() takes microseconds and the slow work is already on other
// queues, so one queue keeps the debounces, one HUD per display and the lights free of locks. Give each
// board a queue of its own if one ever holds the others up.
let engineQueue = DispatchQueue(label: "theej.engine")

// What a connected board's controls last did. Engine queue only.
final class BoardState {
    // By control, never by job, so a control given a new job keeps its old value and the job only lands
    // when the control next moves.
    var lastApplied: [Int: Float32] = [:]
    // A muted control keeps recording its position, so unmuting puts it back where it now is.
    var muted: Set<Int> = []
    var mixer = MixerState()
    var buttons = ButtonWatcher()
    var moves = MoveWatcher()
    var lights: Lights?
    var live: [Int] = []
    var liveQueued = false
    var lastPrint = Date.distantPast
}

var boardStates: [String: BoardState] = [:]

func state(_ id: String) -> BoardState {
    if let state = boardStates[id] { return state }
    let state = BoardState()
    boardStates[id] = state
    return state
}

// A raw frame: a DIY board's line, or a MIDI board's MixerState values.
func frame(_ id: String, _ raw: [Int]) {
    let config = shared.config()
    guard let board = config.setup.board(id) else { return }
    let state = state(id)
    let calibrating = config.calibrating == id
    if calibrating { DispatchQueue.main.async { menuBar?.feedWizard(id, raw) } }
    let values = board.normalize(raw)
    handle(values, of: board, state, calibrating: calibrating)
    if config.watching == id { showLive(id, values, state) }
    guard !calibrating else { return }
    let moved = state.moves.moved(values)
    if config.watching == id, !moved.isEmpty {
        DispatchQueue.main.async { for control in moved { menuBar?.touched(id, control) } }
    }
    for button in state.buttons.pressed(raw, board.buttonInputs, at: ProcessInfo.processInfo.systemUptime) {
        press(board, key: button, state)
    }
}

func handle(_ values: [Int], of board: Board, _ state: BoardState, calibrating: Bool, apply: Applier = applyJobs) {
    let mapping = board.mapping
    var shown: Set<CGDirectDisplayID> = []
    for (control, value) in values.enumerated() where value >= 0 {
        let raw = Float32(value) / 1023
        // A pot often stops a count or two short of its rail, which would leave a light on at its
        // dimmest. Snapping also stops a knob resting by an end from flicking onto it as `extreme`.
        let scalar = raw < deadzone ? 0 : raw > 1 - deadzone ? 1 : raw
        // Tracked, not applied: a control that gains a job (on Apply, or as a calibration ends) waits to be
        // moved instead of jumping there.
        guard !calibrating, let jobs = mapping[control] else {
            state.lastApplied[control] = scalar
            continue
        }
        // The first reading after a connect is only a baseline, so nothing changes until a turn.
        guard let previous = state.lastApplied[control] else {
            state.lastApplied[control] = scalar
            continue
        }
        let extreme = scalar <= 0 || scalar >= 1
        guard scalar != previous, extreme || abs(scalar - previous) >= deadzone else { continue }
        state.lastApplied[control] = scalar
        guard !state.muted.contains(control) else { continue }
        apply(jobs, scalar, board.speed.settle, &shown, true)
    }
    guard !calibrating else { return }
    publishLines(board, state)

    // Silent under launchd (no tty), so the log file doesn't grow forever.
    guard interactive, Date().timeIntervalSince(state.lastPrint) >= 0.5 else { return }
    state.lastPrint = Date()
    let columns = values.enumerated().map { "\(mapping[$0.offset] != nil ? "*" : " ")\($0.offset):\(String(format: "%4d", $0.element))" }
    print("\r\(board.name) \(columns.joined())  ", terminator: "")
    fflush(stdout)
}

// What a control's jobs do at a position: applyJobs, or in the tests a record of it.
typealias Applier = (_ jobs: [Target], _ scalar: Float32, _ settle: Double, _ shown: inout Set<CGDirectDisplayID>, _ hud: Bool) -> Void

// Every job of a control takes its position. A display shows one HUD, the first job's that wants it
// there: two would sit on top of each other. The volumes follow the control. Everything else waits for
// Speed.settle, and the HUD tracks the control live, so the HUD is the only feedback during a turn.
func applyJobs(_ jobs: [Target], _ scalar: Float32, _ settle: Double, _ shown: inout Set<CGDirectDisplayID>, _ hud: Bool) {
    func once(on display: CGDirectDisplayID, _ show: () -> Void) {
        if hud, shown.insert(display).inserted { show() }
    }
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

// Every line, in control order, so a job changed in Settings shows before the control moves.
func publishLines(_ board: Board, _ state: BoardState) {
    let lines = board.mapping.sorted { $0.key < $1.key }.flatMap { control, jobs in
        let level = state.muted.contains(control) ? 0 : state.lastApplied[control] ?? 0
        return jobs.map { (text: "\(title($0)) \(percent(level))%", target: $0) }
    }
    shared.setLines(board.id, lines)
}

// Settings draws the board it shows as it moves, at most 20 times a second, the last values always among them.
func showLive(_ id: String, _ values: [Int], _ state: BoardState) {
    state.live = values
    guard !state.liveQueued else { return }
    state.liveQueued = true
    engineQueue.asyncAfter(deadline: .now() + 0.05) {
        state.liveQueued = false
        let values = state.live
        DispatchQueue.main.async { menuBar?.showValues(id, values) }
    }
}

// Where a job is now, for the jobs that can tell.
func level(of job: Target) -> Float32? {
    switch job {
    case .master: return volume()
    case .microphone: return volume(input: true)
    case .app(let id): return appLevel(id)
    default: return nil
    }
}

// Where a knob that hasn't moved yet starts: where its first job is now, else where it last was, on the
// raw scale normalize reads. nil starts it in the middle.
func seed(_ board: Board, _ state: BoardState, _ column: Int) -> Int? {
    guard let control = board.controls.firstIndex(where: { $0.input == column && $0.kind != .button }),
          let level = board.profile.jobs(of: control).first.flatMap(level(of:)) ?? state.lastApplied[control] else { return nil }
    return board.raw(Int((level * 1023).rounded()), of: control)
}

// The board's MIDI messages, read from its one source.
func midiMessages(_ id: String, _ messages: [UInt32]) {
    let config = shared.config()
    guard let board = config.setup.board(id) else { return }
    let state = state(id)
    let now = ProcessInfo.processInfo.systemUptime
    var changed = false
    for message in messages {
        if let lights = state.lights {
            if let daw = smcMode(message), daw != lights.daw { lights.setMode(daw: daw) }
            guard lights.guardian.pass(message, now: now, lightChanged: lights.lastSent) else { continue }
        }
        let (moved, pressed) = state.mixer.feed(message) { seed(board, state, $0) }
        changed = changed || moved
        if let pressed {
            state.lights?.hold(pressed, true)
            if config.calibrating == id {
                DispatchQueue.main.async { menuBar?.pressWizard(id, pressed) }
            } else {
                press(board, key: pressed, state)
            }
        }
        if let released = smcReleased(message) { state.lights?.hold(released, false) }
    }
    if changed { frame(id, state.mixer.values) }
}

// A button's actions, in order; key is how the board's profiles know it. A mute acts on the board here,
// everything else on the main thread.
func press(_ board: Board, key: Int, _ state: BoardState) {
    let actions = board.profile.buttons[key] ?? []
    log("\(board.controlName(board.control(ofKey: key) ?? key)): \(actions.isEmpty ? "-" : actions.joined(separator: ", "))", for: board.name)
    for action in actions {
        if let control = mutedControl(action) {
            toggleMute(board, control, key: key, state)
        } else {
            DispatchQueue.main.async { perform(action, on: board.id) }
        }
    }
    if shared.config().watching == board.id {
        DispatchQueue.main.async { menuBar?.pressed(board.id, key) }
    }
}

// Muting sets a control's jobs to 0 and keeps recording where it is; unmuting puts them back there. A
// control that hasn't moved yet comes back to where its first job was.
func toggleMute(_ board: Board, _ control: Int, key: Int, _ state: BoardState, apply: Applier = applyJobs) {
    guard board.controls.indices.contains(control), board.controls[control].kind != .button else { return }
    let jobs = board.mapping[control] ?? []
    var shown: Set<CGDirectDisplayID> = []
    if state.muted.insert(control).inserted {
        if state.lastApplied[control] == nil { state.lastApplied[control] = jobs.first.flatMap(level(of:)) }
        apply(jobs, 0, board.speed.settle, &shown, true)
        state.lights?.mute(key, true)
    } else {
        state.muted.remove(control)
        if let last = state.lastApplied[control] { apply(jobs, last, board.speed.settle, &shown, true) }
        state.lights?.mute(key, false)
    }
    publishLines(board, state)
}

// Before a board's profile changes: the next profile gives its muted controls other jobs, so they could no
// longer be unmuted from their buttons. No HUD.
func unmuteAll(_ board: Board, apply: Applier = applyJobs) {
    guard let state = boardStates[board.id], !state.muted.isEmpty else { return }
    var shown: Set<CGDirectDisplayID> = []
    for control in state.muted {
        if let last = state.lastApplied[control] {
            apply(board.mapping[control] ?? [], last, board.speed.settle, &shown, false)
        }
    }
    state.muted = []
    state.lights?.clearMutes()
}

// A DIY board's reader: a thread of its own, since a read blocks. A port or speed change starts a new one.
final class SerialReader {
    let id: String
    let port: String?  // nil finds the board by itself
    let baud: Int
    private let lock = NSLock()
    private var stopped = false

    init(id: String, port: String?, baud: Int) {
        (self.id, self.port, self.baud) = (id, port, baud)
        Thread.detachNewThread { [self] in run() }
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    // Returns early once stopped, so a stopped reader lets go of its port within 250ms.
    private func pause(_ seconds: Double) {
        var left = seconds
        while left > 0, !isStopped {
            Thread.sleep(forTimeInterval: 0.25)
            left -= 0.25
        }
    }

    private func run() {
        let generation = shared.nextGeneration(id)
        let name = shared.config().setup.board(id)?.name ?? id
        func status(_ value: BoardStatus) { shared.setStatus(id, value, generation: generation) }
        while !isStopped {
            // Finding a board by itself skips the ports other boards are open on or set to.
            let set = shared.config().setup.boards.filter { $0.id != id && $0.type == .diy && $0.enabled }.map(\.port)
            guard let path = port ?? findPort(excluding: shared.claimedPorts(besides: id).union(set)) else {
                log("Waiting for a serial device", for: name)
                status(BoardStatus())
                pause(2)
                continue
            }
            guard shared.claim(path, for: id) else {
                pause(2)
                continue
            }
            // O_NONBLOCK to skip the DTR carrier wait, then back to blocking for the read loop.
            let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            let busy = fd < 0 && errno == EBUSY
            guard fd >= 0, configureSerial(fd, baud: baud), fcntl(fd, F_SETFL, 0) == 0 else {
                if fd >= 0 { close(fd) }
                shared.release(path, for: id)
                log("Could not open \(path)", for: name)
                status(BoardStatus(busy: busy, port: path))
                pause(2)
                continue
            }
            log("Connected: \(path)", for: name)
            _ = shared.takeReconnect(id)  // asked for while it waited, which opening it has done
            engineQueue.async { [id] in boardStates[id] = BoardState() }
            status(BoardStatus(connected: true, port: path))
            readUntilDrop(fd)
            close(fd)
            shared.release(path, for: id)
            log("Disconnected", for: name)
            engineQueue.async { [id] in boardStates[id] = nil }
            status(BoardStatus())
            pause(1)
        }
    }

    // poll() with a short timeout rather than a bare blocking read, so a reconnect click is noticed
    // within 250ms. Closing the fd from the main thread to break a blocking read would race on fd reuse.
    private func readUntilDrop(_ fd: Int32) {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 256)
        let problems = Int16(POLLHUP | POLLERR | POLLNVAL)
        // Opening the port resets the Arduino, so the first line can be bootloader noise or half a line.
        // A line counts only when the one before it had as many fields, which drops that and any line
        // that lost a "|" (every column after it would shift).
        var width = 0
        while true {
            if isStopped || shared.takeReconnect(id) { return }
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
                        if values.count == width { engineQueue.async { [id] in frame(id, values) } }
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
}

var serialReaders: [String: SerialReader] = [:]  // main thread only

// After anything that changes the boards: every DIY board that is on has a reader, started again when its
// port or speed changed, MIDI boards follow, and the shortcuts are registered again.
func startBoards() {
    let setup = shared.config().setup
    var keep: Set<String> = []
    for (index, board) in setup.boards.enumerated() where board.type == .diy {
        let own = board.port.isEmpty ? nil : board.port
        let port = setup.boards[..<index].contains { $0.type == .diy } ? own : portOverride ?? own
        guard board.enabled else { continue }
        keep.insert(board.id)
        if let reader = serialReaders[board.id], reader.port == port, reader.baud == board.baud { continue }
        serialReaders[board.id]?.stop()
        serialReaders[board.id] = SerialReader(id: board.id, port: port, baud: board.baud)
    }
    for (id, reader) in serialReaders where !keep.contains(id) {
        reader.stop()
        serialReaders[id] = nil
    }
    midi?.sync()
    registerHotKeys(setup)
}
#endif
