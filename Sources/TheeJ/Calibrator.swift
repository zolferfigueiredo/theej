import Foundation

// Pure, so --selftest can drive it with fake lines and a fake clock. For each knob, phase 0 finds
// its column, 1 to 3 are the slow, fast and slow turns, and 4 is the sweeps.
struct Calibrator {
    static let turnSeconds = 20.0
    static let sweepsNeeded = 10

    private(set) var found: [Int?]
    private(set) var knob = 0
    private(set) var phase = 0
    private(set) var left = turnSeconds
    private(set) var sweeps = 0
    private var low: [Int] = []
    private var high: [Int] = []
    private var anchor = -1
    private var lastMove = -Double.infinity
    private var lastTime = 0.0
    private var armed = false

    init(knobs: Int) { found = Array(repeating: nil, count: knobs) }

    var done: Bool { knob >= found.count }

    mutating func feed(_ values: [Int], at now: Double) {
        guard !done else { return }
        if phase == 0 {
            if low.count != values.count { low = values; high = values }
            for (i, v) in values.enumerated() {
                low[i] = min(low[i], v)
                high[i] = max(high[i], v)
            }
            // The widest swing, not the first past the bar: a pin with no pot echoes the channel
            // read before it, so it moves with the knob.
            let taken = found
            let best = values.indices.filter { !taken.contains($0) }
                .max { high[$0] - low[$0] < high[$1] - low[$1] }
            if let best, high[best] - low[best] >= 512 {
                found[knob] = best
                next()
            }
            return
        }
        guard let column = found[knob], column < values.count else { return }
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

    // Keeps anything already found, so skipping a new knob's turns still records its input.
    mutating func skip() {
        guard !done else { return }
        knob += 1
        reset(0)
    }

    private mutating func next() {
        if phase == 4 { knob += 1; reset(0) } else { reset(phase + 1) }
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
    }
}

// A skipped knob keeps its old input unless this run found that input on another knob.
func calibrated(_ columns: [Int?], found: [Int?]) -> [Int?] {
    let claimed = Set(found.compactMap { $0 })
    return columns.enumerated().map { index, column in
        if index < found.count, let column = found[index] { return column }
        return column.flatMap { claimed.contains($0) ? nil : $0 }
    }
}
