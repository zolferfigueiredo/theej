import Foundation

// What an SMC-Mixer's button lights can show, by the names saved, as weej's lights.go. The EQ ones follow
// the Mac's sound and "clock" the time; lightFrame draws the rest.
let lightPatterns = ["off", "on", "random", "eq", "eq2", "eqgame", "fire", "chase", "bounce", "wave", "sparkle", "blink",
                     "rain", "matrix", "snake", "fill", "explode", "checker", "rise", "zigzag", "orbit", "heartbeat",
                     "stars", "bars", "ball", "comet", "helix", "breathe", "clock"]

// A known pattern, and anything else, "off" included, as "".
func parseLightPattern(_ name: String) -> String {
    name == "off" || !lightPatterns.contains(name) ? "" : name
}

// The pattern after this one, from the last back to "".
func nextLightPattern(_ current: String) -> String {
    let index = current.isEmpty ? 0 : lightPatterns.firstIndex(of: current) ?? 0
    return parseLightPattern(lightPatterns[(index + 1) % lightPatterns.count])
}

// The pattern before this one, from "" back to the last.
func previousLightPattern(_ current: String) -> String {
    let index = current.isEmpty ? 0 : lightPatterns.firstIndex(of: current) ?? 0
    return parseLightPattern(lightPatterns[(index - 1 + lightPatterns.count) % lightPatterns.count])
}

func animated(_ pattern: String) -> Bool { !["", "off", "on"].contains(pattern) }

func isEQ(_ pattern: String) -> Bool { ["eq", "eq2", "eqgame"].contains(pattern) }

// The strip buttons as a grid by each row's first note: eight columns, and M, S, R and Square from top to
// bottom. The bottom row is left out: lighting it sets a real mixer sending fader moves nobody made.
private let lightRows = [16, 8, 0, 24]
private let gridColumns = 8, gridRows = 4

private struct Grid {
    var cells = Array(repeating: false, count: gridRows * gridColumns)

    mutating func set(_ row: Int, _ column: Int) {
        if (0..<gridRows).contains(row), (0..<gridColumns).contains(column) { cells[row * gridColumns + column] = true }
    }

    mutating func column(_ column: Int) { for row in 0..<gridRows { set(row, column) } }

    // A column's bottom `height` rows.
    mutating func fillUp(_ column: Int, _ height: Int) {
        var row = gridRows - height
        while row < gridRows {
            set(row, column)
            row += 1
        }
    }

    mutating func all() { for column in 0..<gridColumns { self.column(column) } }

    var ids: [Int] { cells.indices.filter { cells[$0] }.map { noteButton(lightRows[$0 / gridColumns] + $0 % gridColumns) } }
}

// A number that looks random but is the same for the same a and b, so a pattern draws the same at the
// same moment.
private func noise(_ a: Int, _ b: Int) -> Int {
    var h = (UInt32(truncatingIfNeeded: a) &* 2654435761) ^ (UInt32(truncatingIfNeeded: b) &* 2246822519)
    h ^= h >> 15
    h = h &* 2654435761
    return Int(h >> 13)
}

// 0, 1 ... top, top - 1 ... 1, 0, 1 ... as n grows.
private func triangle(_ n: Int, _ top: Int) -> Int {
    let m = n % (2 * top)
    return m > top ? 2 * top - m : m
}

private let serpentine = (0..<gridRows).flatMap { row in
    (0..<gridColumns).map { k in row * gridColumns + (row % 2 == 1 ? gridColumns - 1 - k : k) }
}

// The grid's edge, clockwise from the top left.
private let border = Array(0..<gridColumns) + (1..<gridRows).map { $0 * gridColumns + gridColumns - 1 }
    + stride(from: gridColumns - 2, through: 0, by: -1).map { (gridRows - 1) * gridColumns + $0 }
    + stride(from: gridRows - 2, to: 0, by: -1).map { $0 * gridColumns }

// What "random" shows t seconds after it started: each of the others in turn for 6 seconds, in a shuffled
// order, then another, never the same twice in a row. On, the EQs and the clock are left out.
func randomPattern(_ t: Double) -> String {
    let pool = lightPatterns.filter { animated($0) && $0 != "random" && !isEQ($0) && $0 != "clock" }
    func round(_ r: Int) -> [String] { pool.indices.map { noise(r, $0) << 8 | $0 }.sorted().map { pool[$0 & 0xFF] } }
    let n = Int(t / 6)
    let (r, position) = (n / pool.count, n % pool.count)
    var order = round(r)
    if r > 0, order[0] == round(r - 1)[pool.count - 1] { order.swapAt(0, 1) }
    return order[position]
}

// The buttons a pattern lights t seconds after it started.
func lightFrame(_ name: String, _ t: Double) -> [Int] {
    let pattern = name == "random" ? randomPattern(t) : name
    var g = Grid()
    func step(_ every: Double) -> Int { Int(t / every) }
    switch pattern {
    case "on": g.all()
    case "blink": if step(0.5) % 2 == 0 { g.all() }
    case "chase": g.column(step(0.12) % gridColumns)
    case "bounce": g.column(triangle(step(0.09), gridColumns - 1))
    case "wave":
        for column in 0..<gridColumns {
            g.fillUp(column, Int((2 + 2 * sin(2 * Double.pi * (t / 1.6 - Double(column) / 8))).rounded()))
        }
    case "sparkle":
        let s = step(0.15)
        for cell in 0..<32 where noise(s, cell) % 4 == 0 { g.set(cell / gridColumns, cell % gridColumns) }
    case "fire":
        let s = step(0.08)
        for column in 0..<gridColumns {
            g.fillUp(column, noise(s, column + 50) % 6 == 0 ? gridRows : 1 + noise(s, column) % 3)
        }
    case "rain", "matrix":
        let (every, tail) = pattern == "matrix" ? (0.14, 2) : (0.11, 1)
        let s = step(every)
        for column in 0..<gridColumns {
            let cycle = gridRows + tail + noise(column, 7) % 4
            let head = (s + noise(column, 3)) % cycle
            for k in 0..<tail { g.set(head - k, column) }
        }
    case "snake":
        let head = step(0.07) % serpentine.count
        for k in 0..<5 {
            let cell = serpentine[(head - k + serpentine.count) % serpentine.count]
            g.set(cell / gridColumns, cell % gridColumns)
        }
    case "fill":
        let s = step(0.15) % (2 * gridColumns)
        for column in 0..<gridColumns where s < gridColumns && column <= s || s >= gridColumns && column > s - gridColumns {
            g.column(column)
        }
    case "explode":
        let r = step(0.12) % 5
        for column in 0..<gridColumns where Int(abs(Double(column) - 3.5).rounded(.up)) == r { g.column(column) }
    case "checker":
        let s = step(0.4)
        for cell in 0..<32 where (cell / gridColumns + cell % gridColumns + s) % 2 == 0 {
            g.set(cell / gridColumns, cell % gridColumns)
        }
    case "rise":
        let s = step(0.15) % (2 * gridRows)
        for column in 0..<gridColumns {
            if s < gridRows {
                g.fillUp(column, s + 1)
            } else {
                for row in 0..<(2 * gridRows - 1 - s) { g.set(row, column) }
            }
        }
    case "zigzag":
        let s = step(0.1)
        for column in 0..<gridColumns { g.set(triangle(column + s, gridRows - 1), column) }
    case "orbit":
        let head = step(0.06) % border.count
        for k in 0..<4 {
            let cell = border[(head - k + border.count) % border.count]
            g.set(cell / gridColumns, cell % gridColumns)
        }
    case "heartbeat":
        let p = t.truncatingRemainder(dividingBy: 1.2)
        if p < 0.1 || p >= 0.22 && p < 0.32 { for column in 2..<6 { g.column(column) } }
    case "stars":
        let s = step(0.4)
        for cell in 0..<32 where noise(s, cell) % 10 == 0 { g.set(cell / gridColumns, cell % gridColumns) }
    case "bars":
        let s = step(0.15)
        for column in 0..<gridColumns { g.fillUp(column, noise(s, column) % (gridRows + 1)) }
    case "ball":
        g.set(triangle(step(0.13), gridRows - 1), triangle(step(0.1), gridColumns - 1))
    case "comet":
        let head = step(0.09) % (gridColumns + 2)
        g.column(head)
        g.set(1, head - 1)
        g.set(2, head - 1)
        g.set(2, head - 2)
    case "helix":
        let s = step(0.12)
        for column in 0..<gridColumns {
            let row = triangle(column + s, gridRows - 1)
            g.set(row, column)
            g.set(gridRows - 1 - row, column)
        }
    case "breathe":
        switch [0, 1, 2, 2, 1, 0][step(0.25) % 6] {
        case 1:
            for column in 0..<gridColumns {
                g.set(1, column)
                g.set(2, column)
            }
        case 2: g.all()
        default: break
        }
    default: break
    }
    return g.ids
}

// Each column as high as its band of the sound, each band 0 to 1, lowest first.
func eqFrame(_ bands: [Double]) -> [Int] {
    var g = Grid()
    for (column, band) in bands.prefix(gridColumns).enumerated() {
        g.fillUp(column, Int((min(max(band, 0), 1) * Double(gridRows) - 0.25).rounded(.up)))
    }
    return g.ids
}

// The time as a binary clock: hours, minutes and seconds, two columns each, one digit per column, from 1 on
// the bottom row to 8 on the top.
func clockFrame(_ date: Date, calendar: Calendar = .current) -> [Int] {
    var g = Grid()
    let now = calendar.dateComponents([.hour, .minute, .second], from: date)
    for (i, n) in [now.hour ?? 0, now.minute ?? 0, now.second ?? 0].enumerated() {
        for (j, digit) in [n / 10, n % 10].enumerated() {
            for bit in 0..<gridRows where digit >> bit & 1 == 1 { g.set(gridRows - 1 - bit, 1 + 2 * i + j) }
        }
    }
    return g.ids
}

// The LED above a strip's fader blinks while the fader position the computer last sent differs from where
// the fader is, and stops once they match or the fader moves (DAW mode only). So a pitch bend far from the
// fader starts it blinking, and the fader's own position stops it.
func smcStripBlink(_ strip: Int, faderMSB: Int) -> UInt32 {
    UInt32(0xE0 | strip) | UInt32(faderMSB >= 64 ? 0 : 127) << 16
}

func smcStripRestore(_ strip: Int, lsb: Int, msb: Int) -> UInt32 {
    UInt32(0xE0 | strip) | UInt32(lsb) << 8 | UInt32(msb) << 16
}

// MARK: The sound the EQ patterns follow, as weej's spectrum.go

// 4096 samples tell a kick (30 to 80 Hz) from a bass line; at 48 kHz they span 85 ms.
let fftSize = 4096
private let hann = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1)) }
private let twiddles = (0..<fftSize / 2).map { (cos(-2 * Double.pi * Double($0) / Double(fftSize)), sin(-2 * Double.pi * Double($0) / Double(fftSize))) }

// The last fftSize samples of each side of the sound playing. The audio thread adds, the lights read.
final class Spectrum: @unchecked Sendable {
    private let lock = NSLock()
    private var rate = 48000.0
    private var ring = [Array(repeating: 0.0, count: fftSize), Array(repeating: 0.0, count: fftSize)]
    private var position = 0

    func setRate(_ hz: Double) {
        lock.lock(); defer { lock.unlock() }
        if hz > 0 { rate = hz }
    }

    // Each side's samples, -1 to 1, as many of each.
    func add(left: UnsafeBufferPointer<Float32>, right: UnsafeBufferPointer<Float32>) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<min(left.count, right.count) {
            ring[0][position] = Double(left[i])
            ring[1][position] = Double(right[i])
            position = (position + 1) % fftSize
        }
    }

    // Interleaved frames: the first two channels as left and right, or a single one as both.
    func add(interleaved samples: UnsafeBufferPointer<Float32>, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        let second = channels > 1 ? 1 : 0
        var i = 0
        while i + channels <= samples.count {
            ring[0][position] = Double(samples[i])
            ring[1][position] = Double(samples[i + second])
            position = (position + 1) % fftSize
            i += channels
        }
    }

    func add(left: [Float32], right: [Float32]) {
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in add(left: l, right: r) } }
    }

    // The sound's power by FFT bin for a side (0 left, 1 right, nil both), oldest sample first, through a
    // Hann window.
    fileprivate func power(_ side: Int?) -> (power: [Double], rate: Double) {
        lock.lock()
        var real = (0..<fftSize).map { i -> Double in
            let j = (position + i) % fftSize
            let v = side.map { ring[$0][j] } ?? (ring[0][j] + ring[1][j]) / 2
            return v * hann[i]
        }
        let rate = self.rate
        lock.unlock()
        var imaginary = Array(repeating: 0.0, count: fftSize)
        fft(&real, &imaginary)
        return ((0..<fftSize / 2).map { real[$0] * real[$0] + imaginary[$0] * imaginary[$0] }, rate)
    }
}

// In place, radix 2, fftSize long.
private func fft(_ real: inout [Double], _ imaginary: inout [Double]) {
    let n = real.count
    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 {
            j ^= bit
            bit >>= 1
        }
        j ^= bit
        if i < j {
            real.swapAt(i, j)
            imaginary.swapAt(i, j)
        }
    }
    var size = 2
    while size <= n {
        for start in stride(from: 0, to: n, by: size) {
            for k in 0..<size / 2 {
                let (wr, wi) = twiddles[k * (n / size)]
                let (a, b) = (start + k, start + k + size / 2)
                let (br, bi) = (real[b] * wr - imaginary[b] * wi, real[b] * wi + imaginary[b] * wr)
                (real[b], imaginary[b]) = (real[a] - br, imaginary[a] - bi)
                (real[a], imaginary[a]) = (real[a] + br, imaginary[a] + bi)
            }
        }
        size <<= 1
    }
}

// One side of the sound in bands, each shown against its own recent level, so a column jumps when its part
// of the sound gets louder: against one shared level, the bass stayed full and a kick lit the treble columns
// more than its own.
final class Analyzer {
    private let edges: [Double]
    private let side: Int?
    private var average: [Double]
    private var spread: [Double]
    private var seen: [Bool]
    private var level: [Double]
    private var last = 0.0

    init(_ edges: [Double], side: Int?) {
        self.edges = edges
        self.side = side
        let bands = edges.count - 1
        (average, spread, seen, level) = (Array(repeating: 0, count: bands), Array(repeating: 0, count: bands),
                                          Array(repeating: false, count: bands), Array(repeating: 0, count: bands))
    }

    // Each band from 0 to 1 at now, in seconds. Below -75 dB a band is silence and leaves its average be; a
    // band shows 0.3 at its average and 0.25 more per spread above it, both following it over 1.5 s, and
    // falls by 3 a second.
    func bands(_ spectrum: Spectrum, now: Double) -> [Double] {
        let dt = min(max(now - last, 0), 0.5)
        last = now
        let follow = min(dt / 1.5, 1)
        let (power, rate) = spectrum.power(side)
        for b in level.indices {
            var energy = 0.0
            for k in 1..<power.count {
                let f = Double(k) * rate / Double(fftSize)
                if f >= edges[b], f < edges[b + 1] { energy += power[k] }
            }
            let db = 10 * log10(energy / Double(fftSize * fftSize) + 1e-12)
            var v = 0.0
            if db > -75 {
                if !seen[b] { (average[b], spread[b], seen[b]) = (db, 3, true) }
                v = min(max(0.3 + 0.25 * (db - average[b]) / max(spread[b], 2), 0), 1)
                average[b] += (db - average[b]) * follow
                spread[b] += (abs(db - average[b]) - spread[b]) * follow
            }
            level[b] = max(v, level[b] - 3 * dt)
        }
        return level
    }
}

// What an EQ pattern shows on the eight columns: "eq" and "eq2" are both sides in eight bands each their own
// way, and "eqgame" the left side's four bands from the left, bass first, beside the right side's four from
// the right, so a sound's side shows where it comes from.
final class EQ {
    private let left: Analyzer
    private let right: Analyzer?

    init?(_ pattern: String) {
        switch pattern {
        case "eq": (left, right) = (Analyzer([30, 80, 160, 400, 1000, 2500, 5000, 9000, 16000], side: nil), nil)
        case "eq2": (left, right) = (Analyzer([20, 100, 400, 1000, 2000, 4000, 8000, 13000, 20000], side: nil), nil)
        case "eqgame":
            let edges = [20.0, 400, 3000, 9000, 20000]
            (left, right) = (Analyzer(edges, side: 0), Analyzer(edges, side: 1))
        default: return nil
        }
    }

    // Each column's height from 0 to 1 at now, in seconds.
    func columns(_ spectrum: Spectrum, now: Double) -> [Double] {
        let left = self.left.bands(spectrum, now: now)
        guard let right = right?.bands(spectrum, now: now) else { return left }
        return Array(left.prefix(4)) + right.prefix(4).reversed()
    }
}
