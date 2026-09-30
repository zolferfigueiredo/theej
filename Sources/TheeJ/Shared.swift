import Foundation

// Shared between the serial thread and the menu bar on the main thread.
var menuBar: MenuBar?

final class Shared {
    private let lock = NSLock()
    private var connected = false
    private var port: String?
    // One per knob in menu order: the text the terminal prints too, and the job, for an app's icon.
    private var lines: [(text: String, target: Target)] = []
    private var reconnectFlag = false
    private var setup = Setup.load()
    private var calibrating = false

    func snapshot() -> (connected: Bool, port: String?, lines: [(text: String, target: Target)]) {
        lock.lock(); defer { lock.unlock() }
        return (connected, port, lines)
    }

    func config() -> (setup: Setup, calibrating: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (setup, calibrating)
    }

    func setSetup(_ value: Setup) {
        lock.lock(); setup = value; lock.unlock()
        value.save()
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
        DispatchQueue.main.async {
            menuBar?.refresh()
            if value { menuBar?.calibrateIfNeeded() }
        }
    }

    func setLines(_ value: [(text: String, target: Target)]) {
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
