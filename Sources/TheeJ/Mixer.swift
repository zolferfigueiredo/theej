import Foundation

// The M-VAVE SMC-Mixer, as weej's smc.go reads it: fader i is control i on column 40+i, its knob is
// control 8+i on column 30+i, and a button's id is 128 plus the note it sends in DAW mode. In CC mode M, S
// and the bottom row send CCs; R and Square send nothing.
let smcColumns = [40, 41, 42, 43, 44, 45, 46, 47, 30, 31, 32, 33, 34, 35, 36, 37]

// The bottom row left to right: play, stop, record, rewind, fast-forward, bank left, bank right, up, down,
// left, right. In CC mode they send CC 52 to 62 in that order.
let smcBottomNotes = [94, 93, 95, 91, 92, 46, 47, 96, 97, 98, 99]

// S1 to S8 in CC mode. A real unit's S7 sent 51, the same as its S8.
let smcSCCs = [28, 29, 38, 39, 48, 49, 50, 51]

// DAW mode's faders and knobs land on the CC-mode columns of the same control, and pitch bend on channels
// 9 to 16 past the 128 CCs.
let mixerColumns = 128 + 16

// The mixer by its USB, Bluetooth and MIDI 2.0 name alike.
func isSMCName(_ name: String) -> Bool { name.lowercased().contains("smc-mixer") }

func noteButton(_ note: Int) -> Int { 128 + note }

func buttonNote(_ id: Int) -> Int? { id >= 128 ? id - 128 : nil }

func smcButton(cc: Int) -> Int? {
    switch cc {
    case 20...27: return noteButton(16 + cc - 20)
    case 52...62: return noteButton(smcBottomNotes[cc - 52])
    default: return smcSCCs.firstIndex(of: cc).map { noteButton(8 + $0) }
    }
}

func smcCC(button id: Int) -> Int? {
    guard let note = buttonNote(id) else { return nil }
    switch note {
    case 16..<24: return 20 + note - 16
    case 8..<16: return smcSCCs[note - 8]
    default: return smcBottomNotes.firstIndex(of: note).map { 52 + $0 }
    }
}

// M, S, R and Square for each strip, then the bottom row.
let smcButtonOrder = (0..<8).flatMap { strip in [16, 8, 0, 24].map { noteButton($0 + strip) } } + smcBottomNotes.map(noteButton)

// The only buttons held lights and mutes light: lighting the bottom row sets a real mixer sending fader
// moves nobody made.
let smcStripButtons = Set((0..<32).map(noteButton))

// M1 to M8 mute their faders, and « and » step profiles.
let smcDefaultButtons: [Int: [String]] = Dictionary(uniqueKeysWithValues: (0..<8).map { (noteButton(16 + $0), ["mute:\($0)"]) })
    .merging([noteButton(46): ["profile.previous"], noteButton(47): ["profile.next"]]) { $1 }

// A short message is status | data1 << 8 | data2 << 16, as weej reads them.
private func parts(_ message: UInt32) -> (status: Int, data1: Int, data2: Int) {
    (Int(message & 0xFF), Int(message >> 8 & 0x7F), Int(message >> 16 & 0x7F))
}

// The button a message lets go of: a note off, or a note or CC-mode button at 0.
func smcReleased(_ message: UInt32) -> Int? {
    let (status, data1, data2) = parts(message)
    switch status & 0xF0 {
    case 0x80: return noteButton(data1)
    case 0x90 where data2 == 0: return noteButton(data1)
    case 0xB0 where data2 == 0: return smcButton(cc: data1)
    default: return nil
    }
}

// Lights or clears a button: by its note in DAW mode, or by its CC in CC mode, which R and Square lack.
func smcLight(_ id: Int, on: Bool, daw: Bool) -> UInt32? {
    let value: UInt32 = on ? 127 : 0
    if !daw { return smcCC(button: id).map { 0xB0 | UInt32($0) << 8 | value << 16 } }
    return buttonNote(id).map { 0x90 | UInt32($0) << 8 | value << 16 }
}

// A knob's step is never 0 or 127, and a CC-mode button on the same number never sends anything else.
func isKnobStep(_ cc: Int, _ value: Int) -> Bool { (16..<24).contains(cc) && value != 0 && value != 127 }

// Which mode a message shows the mixer in: notes, pitch bend and knob steps only come in DAW mode, other
// CCs only in CC mode. nil for a message that tells neither.
func smcMode(_ message: UInt32) -> Bool? {
    let (status, data1, data2) = parts(message)
    switch status & 0xF0 {
    case 0x80, 0x90, 0xE0: return true
    case 0xB0: return isKnobStep(data1, data2)
    default: return nil
    }
}

// MIDI short messages as a frame of 0...1023 values. A control that has not moved yet reads -1, since its
// position is unknown until the mixer sends it.
struct MixerState {
    private(set) var values = Array(repeating: -1, count: mixerColumns)

    // The knobs go back to unknown, so each starts again from where its job is.
    mutating func forgetKnobs() {
        for column in 30..<38 { values[column] = -1 }
    }

    // Whether a column changed, and the id of a button just pressed, the same id in either mode. seed is
    // where a knob that hasn't moved yet starts, or nil for the middle.
    mutating func feed(_ message: UInt32, seed: (Int) -> Int? = { _ in nil }) -> (changed: Bool, pressed: Int?) {
        let (status, data1, data2) = parts(message)
        switch status & 0xF0 {
        case 0x90:
            return (false, data2 > 0 ? noteButton(data1) : nil)
        case 0xE0:
            let channel = status & 0x0F
            // The SMC-Mixer only sends the top 7 bits, so its fader tops out at 127 << 7, not 16383.
            return (set(channel < 8 ? 40 + channel : 128 + channel, min(((data1 | data2 << 7) * 1023 + 8128) / 16256, 1023)), nil)
        case 0xB0:
            break
        default:
            return (false, nil)
        }
        if isKnobStep(data1, data2) {
            let column = 30 + data1 - 16
            let position = values[column] >= 0 ? values[column] : seed(column) ?? 512
            // A step moves the knob 4 of 1023, about 130 steps from one end to the other.
            let steps = (data2 & 0x40 != 0 ? -1 : 1) * (data2 & 0x3F)
            return (set(column, min(max(position + steps * 4, 0), 1023)), nil)
        }
        if let id = smcButton(cc: data1) { return (false, data2 > 0 ? id : nil) }
        return (set(data1, (data2 * 1023 + 63) / 127), nil)
    }

    private mutating func set(_ column: Int, _ value: Int) -> Bool {
        guard values[column] != value else { return false }
        values[column] = value
        return true
    }
}

// Which controls moved far enough to be a hand on them rather than a pot's jitter. One that reads -1 (a
// mixer control not heard from yet) counts as moved once it reports.
struct MoveWatcher {
    private var anchor: [Int] = []

    mutating func moved(_ values: [Int]) -> [Int] {
        guard anchor.count == values.count else {
            anchor = values
            return []
        }
        var moved: [Int] = []
        for (index, value) in values.enumerated() where value >= 0 && (anchor[index] < 0 || abs(value - anchor[index]) >= 12) {
            anchor[index] = value
            moved.append(index)
        }
        return moved
    }
}

// When a DIY board's button is pressed. A button reads one end of the range at rest and the other while
// held, whichever way it is wired, so where its input first reads counts as rest.
struct ButtonWatcher {
    private var rest: [Int: Int] = [:]
    private var down: Set<Int> = []
    private var last: [Int: Double] = [:]

    // inputs is each button's serial column by control index. Returns the buttons just pressed.
    mutating func pressed(_ values: [Int], _ inputs: [Int: Int], at now: Double) -> [Int] {
        var pressed: [Int] = []
        for button in inputs.keys.sorted() {
            guard let column = inputs[button], column < values.count, values[column] >= 0 else { continue }
            let value = values[column]
            guard let rest = rest[column] else {
                rest[column] = value
                continue
            }
            let away = abs(value - rest)
            if !down.contains(column), away >= 400 {
                down.insert(column)
                // Contacts bounce for a few milliseconds, which would read as a second press.
                if now - (last[column] ?? -.infinity) >= 0.15 { pressed.append(button) }
                last[column] = now
            } else if down.contains(column), away < 200 {
                down.remove(column)
            }
        }
        return pressed
    }
}

// Holds back the small moves an SMC-Mixer's faders report while its lights change: lit lights pull every
// fader's reading down, so a fader nobody touches seems to move. A bigger move is a hand, followed closely
// until it rests.
struct LightGuard {
    // ponytail: measured on one unit in Oct 2026, where all 32 lights pulled each fader about 3% of its
    // position, up to 4 steps of 127, reported up to 4.3 s after the change. weej holds moves for 0.6 s,
    // which let those through. Widen these if another unit drifts further or longer.
    static let window = 5.0
    static let steps = 5
    private var reported: [Int: Int] = [:]
    private var awake: [Int: Double] = [:]

    // Whether a message should be read, at now, the last light change having been at lightChanged.
    mutating func pass(_ message: UInt32, now: Double, lightChanged: Double) -> Bool {
        guard let (column, value) = potReading(message) else { return true }
        // Within 50 ms of a change the readings jump by up to 10 steps at once.
        let limit = now - lightChanged <= 0.05 ? 10 : LightGuard.steps
        let hand = now < awake[column] ?? 0 || reported[column].map { abs(value - $0) > limit } == true
        if reported[column] != nil, now - lightChanged <= LightGuard.window, !hand { return false }
        if hand { awake[column] = now + 0.3 }
        reported[column] = value
        return true
    }

    // A fader's pitch bend in DAW mode, or a fader's or knob's CC in CC mode, as column and 7-bit value.
    private func potReading(_ message: UInt32) -> (Int, Int)? {
        let (status, data1, data2) = parts(message)
        if (0xE0..<0xE8).contains(status) { return (40 + status - 0xE0, data2) }
        if status & 0xF0 == 0xB0, (30..<38).contains(data1) || (40..<48).contains(data1) { return (data1, data2) }
        return nil
    }
}

// CoreMIDI's MIDI 1.0 universal packets as short messages. Only channel voice packets (type 2) carry
// controls; any other is stepped over by its size, so a long one can't throw the rest out of step.
func shortMessages(_ words: [UInt32]) -> [UInt32] {
    var messages: [UInt32] = []
    var index = 0
    while index < words.count {
        let word = words[index]
        let type = Int(word >> 28)
        if type == 2 { messages.append(word >> 16 & 0xFF | (word >> 8 & 0x7F) << 8 | (word & 0x7F) << 16) }
        index += [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
    }
    return messages
}

func universalPacket(_ message: UInt32) -> UInt32 {
    0x2000_0000 | (message & 0xFF) << 16 | (message >> 8 & 0x7F) << 8 | message >> 16 & 0x7F
}
