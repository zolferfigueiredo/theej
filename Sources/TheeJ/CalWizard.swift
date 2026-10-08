import Foundation

// Finds a board's controls, as weej's calwizard.go. Every knob and fader is read once at 0% and once at
// 100%, each confirmed with Next, which gives each input its ends and its direction; then each is told
// apart by turning it back to 0%. A button is pressed three times.
struct CalWizard {
    enum Stage: Equatable { case zero, full, find, press, done }
    enum Warning: Equatable {
        case wrong(Int)  // an input another control has
        case mismatch  // a press on a different button than the first ones
        case nothing  // no input moved between the 0% and 100% readings
        case unswept  // the input turned didn't move between the 0% and 100% readings
    }

    let midi: Bool
    let order: [Int]  // the controls to find, in turn
    private let original: [Control]
    private(set) var controls: [Control]
    private(set) var position = 0
    private(set) var warning: Warning?
    private(set) var count = 0  // presses of the button being found
    // .zero or .full while the board is read at 0% and at 100%, nil once both are.
    private var reading: Stage?
    private var zero: [Int] = []
    private var full: [Int] = []
    // Each input's value when the current control's turn began, or when a MIDI input first reported, which
    // is where its first move started.
    private var base: [Int] = []
    private var last: [Int] = []
    private var input: Int?
    private var held: Int?

    // A pot found on a DIY board moved this far from where it was; MIDI holds still, so less will do.
    private var find: Int { midi ? 64 : 300 }
    private var wrong: Int { midi ? 64 : 200 }

    init(_ board: Board, controls: [Int]) {
        midi = board.type.isMIDI
        original = board.controls
        self.controls = board.controls
        order = controls.filter { board.controls.indices.contains($0) }
        restart()
    }

    // Again from the 0% reading, with the controls being found cleared so their old inputs don't count as taken.
    private mutating func restart() {
        controls = original
        (position, zero, full, reading) = (0, [], [], nil)
        for k in order {
            controls[k].input = nil
            if controls[k].kind != .button { reading = .zero }
        }
        begin()
    }

    private mutating func begin() {
        (input, count, held, warning) = (nil, 0, nil, nil)
        base = last
    }

    var current: Int? { position < order.count ? order[position] : nil }

    var stage: Stage {
        if let reading { return reading }
        guard let k = current else { return .done }
        return controls[k].kind == .button ? .press : .find
    }

    var done: Bool { reading == nil && current == nil }

    var result: [Control] { controls }

    private mutating func advance() {
        position += 1
        begin()
    }

    // The reading the board is at: 0%, then 100%. A 100% reading where nothing moved goes back to 0%.
    mutating func next() {
        switch reading {
        case .zero:
            (zero, reading, warning) = (last, .full, nil)
        case .full:
            full = last
            if full.indices.contains(where: { ends($0) != nil }) {
                reading = nil
                begin()
            } else {
                (zero, full, reading, warning) = ([], [], .zero, .nothing)
            }
        default:
            break
        }
    }

    // An input's 0% and 100% readings as its ends and direction, when it moved between them.
    private func ends(_ column: Int) -> (min: Int, max: Int, reverse: Bool)? {
        guard column < full.count, full[column] >= 0 else { return nil }
        let at100 = full[column]
        var at0 = column < zero.count ? zero[column] : -1
        // A MIDI control already at 0% sends nothing until it moves, so its 0% is the far end.
        if at0 < 0 { at0 = at100 >= 512 ? 0 : 1023 }
        guard abs(at100 - at0) >= 300 else { return nil }
        return (Swift.min(at0, at100), Swift.max(at0, at100), at100 < at0)
    }

    // The current control as it was, and on to the next.
    mutating func skip() {
        guard let k = current, reading == nil else { return }
        controls[k] = original[k]
        advance()
    }

    mutating func redo() { restart() }

    // A raw frame: a DIY board's line, or a MIDI board's MixerState values.
    mutating func feed(_ raw: [Int]) {
        if last.count < raw.count {
            last += Array(repeating: 0, count: raw.count - last.count)
            base += Array(repeating: -1, count: raw.count - base.count)
        }
        for (index, value) in raw.enumerated() where base[index] < 0 && value >= 0 { base[index] = value }
        defer { last.replaceSubrange(0..<raw.count, with: raw) }
        guard let k = current, reading == nil else { return }
        if controls[k].kind == .button {
            if !midi { feedButton(raw) }
            return
        }
        feedPot(raw)
    }

    private func moved(_ raw: [Int], _ column: Int) -> Int {
        guard column < raw.count, raw[column] >= 0, base[column] >= 0 else { return 0 }
        return raw[column] - base[column]
    }

    // The other control an input belongs to. A DIY board's controls share its columns; a MIDI board's
    // buttons are ids, apart from its pots' columns.
    private func taken(_ input: Int, button: Bool) -> Int? {
        controls.indices.first { index in
            index != current && controls[index].input == input && !(midi && (controls[index].kind == .button) != button)
        }
    }

    private mutating func feedPot(_ raw: [Int]) {
        var best = 0
        var bestColumn: Int?
        for column in raw.indices {
            let distance = abs(moved(raw, column))
            guard distance >= Swift.min(find, wrong) else { continue }
            if let other = taken(column, button: false) {
                if distance >= wrong { warning = .wrong(other) }
                continue
            }
            if distance >= find && distance > best { (best, bestColumn) = (distance, column) }
        }
        guard let column = bestColumn, let k = current else { return }
        guard let (low, high, reverse) = ends(column) else {
            warning = .unswept
            return
        }
        controls[k].input = column
        (controls[k].min, controls[k].max, controls[k].reverse) = (low, high, reverse)
        advance()
    }

    // A DIY button reads at least 400 from its rest while held, and back within 200 once let go.
    private mutating func feedButton(_ raw: [Int]) {
        if let column = held {
            if abs(moved(raw, column)) < 200 { held = nil }
            return
        }
        if let column = raw.indices.first(where: { abs(moved(raw, $0)) >= 400 }) {
            held = column
            press(input: column)
        }
    }

    // A MIDI button's press, by its id.
    mutating func press(_ id: Int) {
        guard let k = current, reading == nil, controls[k].kind == .button, midi else { return }
        press(input: id)
    }

    private mutating func press(input pressed: Int) {
        if let other = taken(pressed, button: true) {
            warning = .wrong(other)
            return
        }
        if let input, input != pressed {
            (self.input, count, warning) = (nil, 0, .mismatch)
            return
        }
        input = pressed
        count += 1
        warning = nil
        if count == 3, let k = current {
            controls[k].input = pressed
            advance()
        }
    }
}
