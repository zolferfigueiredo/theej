import Foundation

// Pure, so the tests can drive it with fake lines and a fake clock. Knobs are found one at a time, in
// the order they are moved, until Finish. For each knob, phase 0 finds its column, 1 to 3 are the slow,
// fast and slow turns, and 4 is the sweeps.
struct Calibrator {
    static let turnSeconds = 20.0
    static let sweepsNeeded = 10

    let saved: [Int?]  // each knob's column before this run, which Skip keeps
    private(set) var found: [Int] = []  // a column per knob, A first
    private(set) var phase = 0
    private(set) var left = turnSeconds
    private(set) var sweeps = 0
    private(set) var full = false  // every value the sketch sends has its knob, so none is left to find
    private(set) var wrongKnob: Int?  // a knob already found, moving while the next one is asked for
    private var low: [Int] = []
    private var high: [Int] = []
    private var anchor = -1
    private var lastMove = -Double.infinity
    private var lastTime = 0.0
    private var armed = false

    init(saved: [Int?] = []) { self.saved = saved }

    // The knob being asked for, then turned.
    var knob: Int { phase == 0 ? found.count : found.count - 1 }

    // Once found, or while asked for if it already had a column that no knob in this run has taken.
    // Otherwise the knob asked for isn't there, and Finish is what's left.
    var canSkip: Bool {
        guard !full else { return false }
        if phase > 0 { return true }
        guard knob < saved.count, let column = saved[knob] else { return false }
        return !found.contains(column)
    }

    // A turning step's timer stops once the knob has been still for a second.
    var paused: Bool { (1...3).contains(phase) && lastTime - lastMove > 1 }

    mutating func feed(_ values: [Int], at now: Double) {
        guard !full else { return }
        if phase == 0 {
            if low.count != values.count { low = values; high = values }
            for (i, v) in values.enumerated() {
                low[i] = min(low[i], v)
                high[i] = max(high[i], v)
            }
            // The widest swing, not the first past the bar: a pin with no pot echoes the channel
            // read before it, so it moves with the knob.
            let taken = found
            guard let best = values.indices.filter({ !taken.contains($0) })
                .max(by: { high[$0] - low[$0] < high[$1] - low[$1] }) else {
                full = true
                return
            }
            // A found knob moving: say so, and start over, so a pin echoing it can't pass for the next knob.
            // ponytail: 200 counts is well clear of a still pot's noise and of crosstalk from the knob
            // being moved. Lower it if a found knob can move a fair way before this notices.
            if let moved = found.indices.first(where: { found[$0] < values.count && high[found[$0]] - low[found[$0]] >= 200 }) {
                wrongKnob = moved
                low = values
                high = values
                return
            }
            if high[best] - low[best] >= 512 {
                found.append(best)
                next()
            }
            return
        }
        guard let column = found.last, column < values.count else { return }
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

    // A knob found in this run skips its turns and sweeps. One asked for keeps its old column.
    mutating func skip() {
        guard canSkip else { return }
        if phase == 0, let column = saved[knob] { found.append(column) }
        reset(0)
    }

    private mutating func next() {
        reset(phase == 4 ? 0 : phase + 1)
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
        wrongKnob = nil
    }
}
