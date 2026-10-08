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
        engineQueue.async {
            let state = BoardState()
            state.lights = destination.map(Lights.init)
            state.lights?.connect()
            boardStates[id] = state
        }
        log("Connected: \(source.name)", for: board.name)
        shared.setStatus(id, BoardStatus(connected: true, port: source.name))
    }

    private func disconnect(_ id: String) {
        guard let input = inputs.removeValue(forKey: id) else { return }
        MIDIPortDisconnectSource(input.port, input.source)
        MIDIPortDispose(input.port)
        engineQueue.async { boardStates[id] = nil }
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

// An SMC-Mixer's button lights: lit while held or while their mute is on. At most 4 change every 10 ms,
// since a real mixer sent fader moves nobody made after a few dozen at once. Engine queue only.
final class Lights {
    let destination: MIDIEndpointRef
    private(set) var daw = true  // the mode the mixer is in, which a light is sent in
    var guardian = LightGuard()
    private(set) var lastSent = -Double.infinity  // seconds of uptime
    private var held: Set<Int> = []
    private var muted: Set<Int> = []
    private var want: [Int: Bool] = [:]
    private var sent: [Int: Bool] = [:]
    private var flushQueued = false

    init(destination: MIDIEndpointRef) { self.destination = destination }

    // Whatever a run before this one left lit goes off.
    func connect() {
        for id in smcStripButtons { want[id] = false }
        flush()
    }

    func hold(_ id: Int, _ down: Bool) {
        guard smcStripButtons.contains(id) else { return }
        if down { held.insert(id) } else { held.remove(id) }
        update(id)
    }

    func mute(_ id: Int, _ on: Bool) {
        guard smcStripButtons.contains(id) else { return }
        if on { muted.insert(id) } else { muted.remove(id) }
        update(id)
    }

    func clearMutes() {
        let ids = muted
        muted = []
        ids.forEach(update)
    }

    // A light is sent differently in each mode, so all of them go again.
    func setMode(daw: Bool) {
        self.daw = daw
        sent = [:]
        flush()
    }

    private func update(_ id: Int) {
        want[id] = held.contains(id) || muted.contains(id)
        flush()
    }

    private func flush() {
        var budget = 4
        for (id, on) in want.sorted(by: { $0.key < $1.key }) where sent[id] != on {
            guard budget > 0 else {
                if !flushQueued {
                    flushQueued = true
                    engineQueue.asyncAfter(deadline: .now() + 0.01) { [self] in
                        flushQueued = false
                        flush()
                    }
                }
                return
            }
            budget -= 1
            sent[id] = on
            if let message = smcLight(id, on: on, daw: daw) {
                midiSend(destination, message)
                lastSent = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    // As TheeJ quits: every light that is on goes off, 4 every 10 ms.
    func off() {
        for (index, id) in sent.filter(\.value).keys.sorted().enumerated() {
            if let message = smcLight(id, on: false, daw: daw) { midiSend(destination, message) }
            if index % 4 == 3 { Thread.sleep(forTimeInterval: 0.01) }
        }
        sent = [:]
        want = [:]
    }
}
#endif
