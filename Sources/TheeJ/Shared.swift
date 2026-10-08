#if canImport(AppKit)
import Foundation

// Shared between the boards' readers and the menu bar on the main thread.
var menuBar: MenuBar?

struct BoardStatus: Equatable {
    var connected = false
    var busy = false  // its port is open in another app
    var port: String?
}

final class Shared {
    private let lock = NSLock()
    private var statuses: [String: BoardStatus] = [:]
    // One per job in control order, per board: the text the terminal prints too, and the job, for an app's icon.
    private var lines: [String: [(text: String, target: Target)]] = [:]
    private var reconnects: Set<String> = []
    private var setup = Setup.load()
    private var calibrating: String?
    private var watching: String?  // the board Settings shows, which is sent its values as they change
    private var claimed: [String: String] = [:]  // a serial port's path, to the board reading it
    private var generations: [String: Int] = [:]  // the reader each board's status comes from

    func config() -> (setup: Setup, calibrating: String?, watching: String?) {
        lock.lock(); defer { lock.unlock() }
        return (setup, calibrating, watching)
    }

    func status(_ id: String) -> BoardStatus {
        lock.lock(); defer { lock.unlock() }
        return statuses[id] ?? BoardStatus()
    }

    func lines(_ id: String) -> [(text: String, target: Target)] {
        lock.lock(); defer { lock.unlock() }
        return lines[id] ?? []
    }

    func setSetup(_ value: Setup) {
        lock.lock(); setup = value; lock.unlock()
        value.save()
    }

    func setCalibrating(_ id: String?) {
        lock.lock(); calibrating = id; lock.unlock()
    }

    func setWatching(_ id: String?) {
        lock.lock(); watching = id; lock.unlock()
    }

    // A reader takes a generation as it starts, so a reader that was replaced can't overwrite the status of
    // the one that took its place.
    func nextGeneration(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        generations[id, default: 0] += 1
        return generations[id]!
    }

    func setStatus(_ id: String, _ value: BoardStatus, generation: Int? = nil) {
        lock.lock()
        guard generation == nil || generation == generations[id] else { return lock.unlock() }
        let changed = statuses[id] != value
        statuses[id] = value
        if !value.connected { lines[id] = nil }
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async {
            menuBar?.statusChanged(id)
            if value.connected { menuBar?.calibrateIfNeeded(id) }
        }
    }

    func setLines(_ id: String, _ value: [(text: String, target: Target)]) {
        lock.lock(); lines[id] = value; lock.unlock()
    }

    // A DIY board's reader takes it; nil asks every DIY board. MIDI.reconnect does a MIDI board's.
    func requestReconnect(_ id: String?) {
        lock.lock()
        if let id { reconnects.insert(id) } else { reconnects.formUnion(setup.boards.filter { $0.type == .diy }.map(\.id)) }
        lock.unlock()
    }

    func takeReconnect(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return reconnects.remove(id) != nil
    }

    // Opening a serial port resets a CH340 Arduino, so two boards never open the same one.
    func claim(_ path: String, for id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard claimed[path] == nil || claimed[path] == id else { return false }
        claimed[path] = id
        return true
    }

    func release(_ path: String, for id: String) {
        lock.lock()
        if claimed[path] == id { claimed[path] = nil }
        lock.unlock()
    }

    func claimedPorts(besides id: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(claimed.filter { $0.value != id }.keys)
    }
}

let shared = Shared()
#endif
