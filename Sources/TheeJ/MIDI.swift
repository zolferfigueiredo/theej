#if canImport(AppKit)
import CoreMIDI
import Foundation

var midi: MIDI?  // main thread only
private var lightsPort = MIDIPortRef()  // made once, before any light is sent

func displayName(_ object: MIDIObjectRef) -> String {
    var name: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name) == noErr, let name else { return "" }
    return name.takeRetainedValue() as String
}

// Each enabled MIDI board reads one source, and an SMC-Mixer lights its buttons through the destination
// beside it. A USB SMC-Mixer has two sources, Master and Private, that both send everything, so each
// device goes to one board only, or every press would count twice.
final class MIDI {
    private var client = MIDIClientRef()
    private var inputs: [String: (port: MIDIPortRef, source: MIDIEndpointRef)] = [:]

    init() {
        // The notifications come on a thread of CoreMIDI's choosing.
        MIDIClientCreateWithBlock("TheeJ" as CFString, &client) { _ in DispatchQueue.main.async { midi?.sync() } }
        MIDIOutputPortCreate(client, "TheeJ lights" as CFString, &lightsPort)
    }

    // The sources there are now: a device that is unplugged has none.
    static func sources() -> [(ref: MIDIEndpointRef, name: String)] {
        (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.map { ($0, displayName($0)) }
    }

    private static func device(of endpoint: MIDIEndpointRef) -> MIDIDeviceRef {
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        MIDIEntityGetDevice(entity, &device)
        return device == 0 ? endpoint : device  // a virtual source has no device of its own
    }

    private static func destination(beside source: MIDIEndpointRef) -> MIDIEndpointRef? {
        var entity = MIDIEntityRef()
        guard MIDIEndpointGetEntity(source, &entity) == noErr, MIDIEntityGetNumberOfDestinations(entity) > 0 else { return nil }
        return MIDIEntityGetDestination(entity, 0)
    }

    // A board's source: the one it was set to, or for an SMC-Mixer with none there, whichever SMC-Mixer is
    // plugged in, by USB or Bluetooth, Master before Private.
    private func source(for board: Board, among sources: [(ref: MIDIEndpointRef, name: String)],
                        besides taken: Set<MIDIDeviceRef>) -> (ref: MIDIEndpointRef, name: String)? {
        let free = sources.filter { !taken.contains(MIDI.device(of: $0.ref)) }
        if let exact = free.first(where: { $0.name == board.port }) { return exact }
        guard board.type == .smc else { return nil }
        let mixers = free.filter { isSMCName($0.name) }
        return mixers.first { $0.name.lowercased().hasSuffix("master") }
            ?? mixers.first { !$0.name.lowercased().contains("private") } ?? mixers.first
    }

    func reconnect(_ id: String) {
        disconnect(id)
        sync()
    }

    // Main thread, as boards change and as devices come and go. A board set to a source that is there gets
    // it before one on Automatic can take the device.
    func sync(reconnect: Bool = false) {
        let setup = shared.config().setup
        let wanted = setup.boards.filter { $0.enabled && $0.type.isMIDI }
        for id in inputs.keys where reconnect || !wanted.contains(where: { $0.id == id }) { disconnect(id) }
        let sources = MIDI.sources()
        let named = Set(sources.map(\.name))
        var taken: Set<MIDIDeviceRef> = []
        for board in wanted.filter({ named.contains($0.port) }) + wanted.filter({ !named.contains($0.port) }) {
            let pick = source(for: board, among: sources, besides: taken)
            if let pick { taken.insert(MIDI.device(of: pick.ref)) }
            if inputs[board.id]?.source == pick?.ref, pick != nil { continue }
            disconnect(board.id)
            if let pick {
                connect(board, pick)
            } else {
                log("Waiting for MIDI input \(board.port.isEmpty ? "SMC-Mixer" : board.port)", for: board.name)
                shared.setStatus(board.id, BoardStatus())
            }
        }
    }

    private func connect(_ board: Board, _ source: (ref: MIDIEndpointRef, name: String)) {
        let id = board.id
        var port = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(client, "TheeJ \(id)" as CFString, ._1_0, &port) { list, _ in
            var words: [UInt32] = []
            for packet in list.unsafeSequence() { words += packet.words() }
            let messages = shortMessages(words)
            if !messages.isEmpty { engineQueue.async { midiMessages(id, messages) } }
        }
        guard status == noErr, MIDIPortConnectSource(port, source.ref, nil) == noErr else {
            log("Could not open \(source.name)", for: board.name)
            return
        }
        inputs[id] = (port, source.ref)
        let destination = board.type == .smc ? MIDI.destination(beside: source.ref) : nil
        let pattern = board.lights
        engineQueue.async {
            let state = BoardState()
            state.lights = destination.map(Lights.init)
            state.lights?.connect(faders: savedFaders(id), pattern: pattern)
            boardStates[id] = state
        }
        log("Connected: \(source.name)", for: board.name)
        shared.setStatus(id, BoardStatus(connected: true, port: source.name))
    }

    private func disconnect(_ id: String) {
        guard let input = inputs.removeValue(forKey: id) else { return }
        MIDIPortDisconnectSource(input.port, input.source)
        MIDIPortDispose(input.port)
        engineQueue.async {
            if let lights = boardStates[id]?.lights { saveFaders(id, lights.faders) }
            boardStates[id] = nil
        }
        shared.setStatus(id, BoardStatus())
    }
}

func midiSend(_ destination: MIDIEndpointRef, _ message: UInt32) {
    var list = MIDIEventList()
    var word = universalPacket(message)
    withUnsafeMutablePointer(to: &list) { pointer in
        let packet = MIDIEventListInit(pointer, ._1_0)
        _ = MIDIEventListAdd(pointer, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        _ = MIDISendEventList(lightsPort, destination, pointer)
    }
}

// The sound the EQ patterns follow, which the sound tap fills while one of them runs.
let spectrum = Spectrum()

// A fader's LED only stops when the mixer is told where the fader is, and a fader doesn't move while TheeJ
// is closed, so each SMC-Mixer's faders are kept between runs, by board: [lsb, msb] or null per strip.
func savedFaders(_ id: String) -> [Int: (lsb: Int, msb: Int)] {
    let saved = prefs.dictionary(forKey: "mixerFaders")?[id] as? [Any] ?? []
    var faders: [Int: (lsb: Int, msb: Int)] = [:]
    for (strip, pair) in saved.prefix(8).enumerated() {
        if let pair = pair as? [Int], pair.count == 2 { faders[strip] = (pair[0] & 0x7F, pair[1] & 0x7F) }
    }
    return faders
}

func saveFaders(_ id: String, _ faders: [Int: (lsb: Int, msb: Int)]) {
    var saved = prefs.dictionary(forKey: "mixerFaders") ?? [:]
    saved[id] = (0..<8).map { strip -> Any in faders[strip].map { [$0.lsb, $0.msb] } ?? NSNull() }
    prefs.set(saved, forKey: "mixerFaders")
}

// An SMC-Mixer's button lights: its pattern, and a button lit while held or while its mute is on, all on the
// strip buttons. At most 4 change every 10 ms, since a real mixer sent fader moves nobody made after a few
// dozen at once. The LED over a fader blinks while its knob turns. Engine queue only.
final class Lights {
    let destination: MIDIEndpointRef
    private(set) var daw = true  // the mode the mixer is in, which a light is sent in
    var guardian = LightGuard()
    private(set) var lastSent = -Double.infinity  // seconds of uptime
    private(set) var faders: [Int: (lsb: Int, msb: Int)] = [:]  // each fader's last pitch bend, as it came
    private var held: Set<Int> = []
    private var muted: Set<Int> = []
    private var want: [Int: Bool] = [:]
    private var sent: [Int: Bool] = [:]
    private var flushQueued = false
    private var pattern = ""
    private var started = 0.0
    private var eq: EQ?
    private var ticker: DispatchSourceTimer?
    private var knobUntil = Array(repeating: 0.0, count: 8)  // when each strip's LED stops blinking for its knob
    private var blinking: [UInt32?] = Array(repeating: nil, count: 8)  // the message keeping each one blinking

    init(destination: MIDIEndpointRef) { self.destination = destination }

    deinit { ticker?.cancel() }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // Whatever a run before this one left lit goes off, and the faders are where they were left.
    func connect(faders: [Int: (lsb: Int, msb: Int)], pattern: String) {
        self.faders = faders
        for id in smcStripButtons { want[id] = false }
        setPattern(pattern)
    }

    func setPattern(_ name: String) {
        let name = parseLightPattern(name)
        if name != pattern { (pattern, started, eq) = (name, now, EQ(name)) }
        update()
    }

    func hold(_ id: Int, _ down: Bool) {
        guard smcStripButtons.contains(id) else { return }
        if down { held.insert(id) } else { held.remove(id) }
        update()
    }

    func mute(_ id: Int, _ on: Bool) {
        guard smcStripButtons.contains(id) else { return }
        if on { muted.insert(id) } else { muted.remove(id) }
        update()
    }

    func clearMutes() {
        muted = []
        update()
    }

    // A fader moving puts the LED over it out on the mixer itself.
    func faderMoved(_ strip: Int, lsb: Int, msb: Int) {
        guard (0..<8).contains(strip) else { return }
        faders[strip] = (lsb, msb)
        blinking[strip] = nil
    }

    // ponytail: 0.3 s past the knob's last step, so the LED doesn't flicker between steps, as weej's knobTail.
    func knobTurned(_ strip: Int) {
        guard (0..<8).contains(strip) else { return }
        knobUntil[strip] = now + 0.3
        update()
    }

    // A light is sent differently in each mode, so all of them go again, and any LED still blinking from
    // before is settled on the fader's place.
    func setMode(daw: Bool) {
        self.daw = daw
        sent = [:]
        blinking = Array(repeating: nil, count: 8)
        if daw { for (strip, fader) in faders { midiSend(destination, smcStripRestore(strip, lsb: fader.lsb, msb: fader.msb)) } }
        update()
    }

    private func update() {
        let now = now
        let knobs = knobUntil.contains { $0 > now }
        if animated(pattern) || knobs {
            if ticker == nil {
                let timer = DispatchSource.makeTimerSource(queue: engineQueue)
                timer.schedule(deadline: .now() + 0.04, repeating: 0.04, leeway: .milliseconds(5))
                timer.setEventHandler { [weak self] in self?.update() }
                timer.resume()
                ticker = timer
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
        let frame: [Int]
        if let eq {
            frame = eqFrame(eq.columns(spectrum, now: now - started))
        } else if pattern == "clock" {
            frame = clockFrame(Date())
        } else {
            frame = lightFrame(pattern, now - started)
        }
        let lit = Set(frame).union(held).union(muted)
        for id in smcStripButtons { want[id] = lit.contains(id) }
        flush()
        for strip in 0..<8 { blink(strip, knobUntil[strip] > now) }
    }

    // Once the fader has said where it is: only its own place stops a blink. A blinking LED flashes on its
    // own, so it counts as a light change for the guard.
    private func blink(_ strip: Int, _ on: Bool) {
        guard daw, let fader = faders[strip] else { return }
        if on {
            let message = smcStripBlink(strip, faderMSB: fader.msb)
            if blinking[strip] != message {
                midiSend(destination, message)
                blinking[strip] = message
            }
            lastSent = now
        } else if blinking[strip] != nil {
            midiSend(destination, smcStripRestore(strip, lsb: fader.lsb, msb: fader.msb))
            blinking[strip] = nil
            lastSent = now
        }
    }

    private func flush() {
        var budget = 4
        for (id, on) in want.sorted(by: { $0.key < $1.key }) where sent[id] != on {
            guard budget > 0 else {
                if !flushQueued {
                    flushQueued = true
                    engineQueue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.flushQueued = false
                        self?.flush()
                    }
                }
                return
            }
            budget -= 1
            sent[id] = on
            if let message = smcLight(id, on: on, daw: daw) {
                midiSend(destination, message)
                lastSent = now
            }
        }
    }

    // As TheeJ quits: the blinks stop, and every light that is on goes off, 4 every 10 ms.
    func off() {
        ticker?.cancel()
        ticker = nil
        knobUntil = Array(repeating: 0, count: 8)
        for strip in 0..<8 { blink(strip, false) }
        for (index, id) in sent.filter(\.value).keys.sorted().enumerated() {
            if let message = smcLight(id, on: false, daw: daw) { midiSend(destination, message) }
            if index % 4 == 3 { Thread.sleep(forTimeInterval: 0.01) }
        }
        sent = [:]
        want = [:]
    }
}
#endif
