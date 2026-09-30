import Foundation

// Pure, so the tests can drive it with fake lines and a fake clock. Knobs are found one at a time, in
// the order they are moved, until Finish. For each knob, phase 0 finds its column and phase 1 is the
// turning that cleans it, which a knob can skip once it is found.
struct Calibrator {
    static let turnSeconds = 20.0

    let saved: [Int?]  // each knob's column before this run, which Skip keeps
    let onlyNew: Bool  // pass by every knob that keeps its column, so only the ones without are asked for
    private(set) var first = 0  // the first knob asked for
    private(set) var found: [Int] = []  // a column per knob, A first
    private(set) var phase = 0
    private(set) var left = turnSeconds
    private(set) var full = false  // every value the sketch sends has its knob, so none is left to find
    private(set) var wrongKnob: Int?  // a knob already found, moving while the next one is asked for
    private var low: [Int] = []
    private var high: [Int] = []
    private var anchor = -1
    private var lastMove = -Double.infinity
    private var lastTime = 0.0
    private var stepStart = Double.infinity  // the turning's first line; not yet while infinite

    init(saved: [Int?] = [], onlyNew: Bool = false) {
        self.saved = saved
        self.onlyNew = onlyNew
        skipKept()
        first = knob
    }

    // The knob being asked for, then turned.
    var knob: Int { phase == 0 ? found.count : found.count - 1 }

    // Only a knob that is found: in this run, or before it with a column no other knob here has taken.
    // Otherwise the knob asked for isn't there, and Finish is what's left.
    var canSkip: Bool {
        guard !full else { return false }
        if phase > 0 { return true }
        guard knob < saved.count, let column = saved[knob] else { return false }
        return !found.contains(column)
    }

    // The columns Finish saves: the knobs this run found or kept, then the rest as they were, less any
    // column this run found on another knob.
    var result: [Int?] {
        found + saved.dropFirst(found.count).map { $0.flatMap { found.contains($0) ? nil : $0 } }
    }

    // The turning's timer stops once the knob has been still for a second. Counted from its start too,
    // or it would open on "paused" until the knob first moves 10 counts.
    var paused: Bool { phase == 1 && lastTime - max(lastMove, stepStart) > 1 }

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
        // Checked before lastMove moves on, so the gap of a reconnect never counts.
        if anchor < 0 { anchor = value; stepStart = now }
        if now - lastMove <= 1 { left -= now - lastTime }
        if abs(value - anchor) >= 10 { anchor = value; lastMove = now }
        lastTime = now
        if left <= 0 { next() }
    }

    // A knob found in this run skips its turning. One asked for keeps its old column.
    mutating func skip() {
        guard canSkip else { return }
        if phase == 0, let column = saved[knob] { found.append(column) }
        reset(0)
        skipKept()
    }

    private mutating func next() {
        reset(phase == 1 ? 0 : 1)
        skipKept()
    }

    private mutating func skipKept() {
        while onlyNew, phase == 0, canSkip, let column = saved[knob] {
            found.append(column)
            reset(0)
        }
    }

    private mutating func reset(_ newPhase: Int) {
        phase = newPhase
        low = []
        high = []
        left = Self.turnSeconds
        anchor = -1
        lastMove = -.infinity
        stepStart = .infinity
        wrongKnob = nil
    }
}
