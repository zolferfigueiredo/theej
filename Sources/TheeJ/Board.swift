import Foundation

// How TheeJ reads a board: lines of values over serial, the SMC-Mixer's fixed MIDI controls, or any other
// MIDI controller, which is calibrated like a DIY board. The raw values are saved.
enum BoardType: String, Codable, CaseIterable {
    case diy, smc, midi

    var isMIDI: Bool { self != .diy }
}

enum ControlKind: String, Codable, CaseIterable {
    case knob, fader, button
}

// input is where calibration found the control, nil until then: a serial column on a DIY board, a
// MixerState column for a MIDI knob or fader, and the id a MIDI button sends. min and max are the raw ends
// of a pot's travel, and reverse puts its 0% at max.
struct Control: Codable, Equatable {
    var kind: ControlKind
    var input: Int?
    var reverse = false
    var min = 0
    var max = 1023

    enum CodingKeys: String, CodingKey { case kind, input, reverse, min, max }

    init(kind: ControlKind, input: Int? = nil, reverse: Bool = false, min: Int = 0, max: Int = 1023) {
        (self.kind, self.input, self.reverse, self.min, self.max) = (kind, input, reverse, min, max)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? values.decode(ControlKind.self, forKey: .kind)) ?? .knob
        input = (try? values.decodeIfPresent(Int.self, forKey: .input)).flatMap { $0 >= 0 ? $0 : nil }
        reverse = (try? values.decode(Bool.self, forKey: .reverse)) ?? false
        min = (try? values.decode(Int.self, forKey: .min)) ?? 0
        max = (try? values.decode(Int.self, forKey: .max)) ?? 1023
        if min < 0 || max > 1023 || max <= min { (min, max) = (0, 1023) }
    }
}

// One board with everything that belongs to it. id never changes and is never given to another board.
struct Board: Codable, Equatable {
    var id: String
    var name: String
    var type: BoardType
    var enabled = true
    var port = ""  // "" finds a DIY board by itself; a MIDI input's name otherwise
    var baud = 9600
    var speed = Speed.slow
    var controls: [Control] = []
    var list = false  // shows the List view in place of the drawing
    var layout: [[Int]]?  // a DIY or MIDI board's drawing, rows of control indices; nil draws a row per kind
    var profiles: [Profile] = []
    var active = 0
    var next: Shortcut?
    var previous: Shortcut?
    var lights = ""  // an SMC-Mixer's button light pattern, "" for none

    // The keys and their spelling are WeeJ's, so the two apps' boards read alike.
    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled, port, baud = "baudRate", speed, controls, view, layout, profiles, active = "profile"
        case next = "nextProfile", previous = "previousProfile", lights
    }

    init(id: String, name: String, type: BoardType) {
        (self.id, self.name, self.type) = (id, name, type)
    }

    // Never fails on one bad value: only a board of a type this version doesn't know is dropped.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(BoardType.self, forKey: .type)
        id = (try? values.decode(String.self, forKey: .id)) ?? ""
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? true
        port = (try? values.decode(String.self, forKey: .port)) ?? ""
        baud = (try? values.decode(Int.self, forKey: .baud)).flatMap { $0 > 0 ? $0 : nil } ?? 9600
        speed = (try? values.decode(Speed.self, forKey: .speed)) ?? .slow
        controls = type == .smc ? Board.smcControls : (try? values.decode([Control].self, forKey: .controls)) ?? []
        list = (try? values.decode(String.self, forKey: .view)) == "list"
        layout = type == .smc ? nil : try? values.decodeIfPresent([[Int]].self, forKey: .layout)
        profiles = ((try? values.decode([Lossy<Profile>].self, forKey: .profiles)) ?? []).compactMap(\.value)
        for index in profiles.indices { profiles[index].jobs = fitted(profiles[index].jobs) }
        if profiles.isEmpty { profiles = [newProfile(tr("default_profile"))] }
        active = Swift.min(Swift.max((try? values.decode(Int.self, forKey: .active)) ?? 0, 0), profiles.count - 1)
        next = try? values.decodeIfPresent(Shortcut.self, forKey: .next)
        previous = try? values.decodeIfPresent(Shortcut.self, forKey: .previous)
        lights = type == .smc ? parseLightPattern((try? values.decode(String.self, forKey: .lights)) ?? "") : ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(type, forKey: .type)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(port, forKey: .port)
        try values.encode(baud, forKey: .baud)
        try values.encode(speed, forKey: .speed)
        try values.encode(controls, forKey: .controls)
        try values.encode(list ? "list" : "draw", forKey: .view)
        try values.encodeIfPresent(layout, forKey: .layout)
        try values.encode(profiles, forKey: .profiles)
        try values.encode(active, forKey: .active)
        try values.encodeIfPresent(next, forKey: .next)
        try values.encodeIfPresent(previous, forKey: .previous)
        if !lights.isEmpty { try values.encode(lights, forKey: .lights) }
    }

    // A board with one profile and its knobs, faders and buttons still to find. An SMC-Mixer's controls
    // are fixed, so it takes no counts.
    static func make(id: String, name: String, type: BoardType, knobs: Int = 0, faders: Int = 0, buttons: Int = 0,
                     profileName: String) -> Board {
        var board = Board(id: id, name: name, type: type)
        board.controls = type == .smc ? smcControls
            : [(ControlKind.knob, knobs), (.fader, faders), (.button, buttons)].flatMap { kind, count in
                Array(repeating: Control(kind: kind), count: count)
            }
        board.profiles = [board.newProfile(profileName)]
        return board
    }

    // An empty profile, with an SMC-Mixer's usual buttons.
    func newProfile(_ name: String) -> Profile {
        Profile(name: name, jobs: Array(repeating: [], count: controls.count), buttons: type == .smc ? smcDefaultButtons : [:])
    }

    // An SMC-Mixer's faders, then its knobs, on the columns MixerState gives them.
    static let smcControls = smcColumns.enumerated().map { index, column in
        Control(kind: index < 8 ? .fader : .knob, input: column)
    }

    func fitted(_ jobs: [[Target]]) -> [[Target]] {
        Array(jobs.prefix(controls.count)) + Array(repeating: [], count: Swift.max(0, controls.count - jobs.count))
    }

    var profile: Profile {
        get { profiles[active] }
        set { profiles[active] = newValue }
    }

    // The profile `by` steps away from the active one, round the end either way.
    func stepped(_ by: Int) -> Int { ((active + by) % profiles.count + profiles.count) % profiles.count }

    // A picked control: a control index, or on an SMC-Mixer a button's id from 128.
    func isButton(_ control: Int) -> Bool {
        type == .smc ? control >= controls.count : controls.indices.contains(control) && controls[control].kind == .button
    }

    // How profiles key a button: by control index, and on another MIDI board by the id the button sends.
    func buttonKey(_ control: Int) -> Int? {
        type == .midi ? controls[control].input : control
    }

    func control(ofKey key: Int) -> Int? {
        type == .midi ? controls.firstIndex { $0.kind == .button && $0.input == key } : key
    }

    // The board's buttons as its profiles key them, in the order Settings lists them.
    var buttonKeys: [Int] {
        if type == .smc { return smcButtonOrder }
        return controls.indices.filter { controls[$0].kind == .button }.compactMap(buttonKey)
    }

    // A DIY board's buttons that have an input: control index to its serial column.
    var buttonInputs: [Int: Int] {
        guard type == .diy else { return [:] }
        var inputs: [Int: Int] = [:]
        for (index, control) in controls.enumerated() where control.kind == .button {
            if let input = control.input { inputs[index] = input }
        }
        return inputs
    }

    var calibrated: Bool { !controls.contains { $0.input == nil } }

    // The rows a DIY or MIDI board is drawn in, as weej's CleanLayout keeps a saved layout drawable: a
    // control out of range or seen before goes, and one it misses joins the last row.
    var rows: [[Int]] {
        guard let layout else {
            return ControlKind.allCases.map { kind in controls.indices.filter { controls[$0].kind == kind } }.filter { !$0.isEmpty }
        }
        var seen: Set<Int> = []
        var rows = layout.map { $0.filter { controls.indices.contains($0) && seen.insert($0).inserted } }.filter { !$0.isEmpty }
        let missing = controls.indices.filter { !seen.contains($0) }
        if !missing.isEmpty {
            if rows.isEmpty { rows.append([]) }
            rows[rows.count - 1] += missing
        }
        return rows
    }

    enum Move: CaseIterable { case up, left, down, right }

    func canMove(_ control: Int, _ move: Move) -> Bool {
        let rows = self.rows
        guard let row = rows.firstIndex(where: { $0.contains(control) }), let place = rows[row].firstIndex(of: control) else { return false }
        switch move {
        case .left: return place > 0
        case .right: return place < rows[row].count - 1
        // Past the first or last row starts a new one, unless the control is alone in its row.
        case .up: return row > 0 || rows[row].count > 1
        case .down: return row < rows.count - 1 || rows[row].count > 1
        }
    }

    mutating func move(_ control: Int, _ move: Move) {
        guard canMove(control, move) else { return }
        var rows = self.rows
        let row = rows.firstIndex { $0.contains(control) }!
        let place = rows[row].firstIndex(of: control)!
        switch move {
        case .left, .right:
            rows[row].swapAt(place, place + (move == .left ? -1 : 1))
        case .up, .down:
            let to = row + (move == .up ? -1 : 1)
            rows[row].remove(at: place)
            if to < 0 {
                rows.insert([control], at: 0)
            } else if to == rows.count {
                rows.append([control])
            } else {
                rows[to].insert(control, at: Swift.min(place, rows[to].count))
            }
            rows.removeAll { $0.isEmpty }
        }
        layout = rows
    }

    // A raw frame as one value per control, 0 for 0% to 1023 for 100%. Buttons, controls not found yet and
    // inputs that haven't reported read -1. The outer 2% of a pot's travel counts as that end, so a worn
    // pot still reaches 0% and 100%.
    func normalize(_ raw: [Int]) -> [Int] {
        controls.map { control in
            guard control.kind != .button, let input = control.input, input < raw.count, raw[input] >= 0 else { return -1 }
            var (low, high) = control.max > control.min ? (control.min, control.max) : (0, 1023)
            let dead = (high - low) * 20 / 1000
            (low, high) = (low + dead, high - dead)
            let value = Swift.min(Swift.max((raw[input] - low) * 1023 / Swift.max(high - low, 1), 0), 1023)
            return control.reverse ? 1023 - value : value
        }
    }

    // The raw reading normalize turns into value, for a knob that starts where its job is.
    func raw(_ value: Int, of control: Int) -> Int {
        let pot = controls[control]
        var (low, high) = pot.max > pot.min ? (pot.min, pot.max) : (0, 1023)
        let dead = (high - low) * 20 / 1000
        (low, high) = (low + dead, high - dead)
        return low + (pot.reverse ? 1023 - value : value) * (high - low) / 1023
    }

    // Each found knob's and fader's jobs in the active profile, by control index.
    var mapping: [Int: [Target]] {
        var mapping: [Int: [Target]] = [:]
        for (index, control) in controls.enumerated() where control.kind != .button && control.input != nil {
            let jobs = profile.jobs(of: index)
            if !jobs.isEmpty { mapping[index] = jobs }
        }
        return mapping
    }

    // Every app a control sets the volume of, in any profile.
    var apps: Set<String> {
        Set(profiles.flatMap(\.jobs).joined().compactMap { job in
            if case .app(let id) = job { return id }
            return nil
        })
    }

    func controlName(_ control: Int) -> String {
        if type == .smc { return smcControlName(control) }
        switch controls.indices.contains(control) ? controls[control].kind : .knob {
        case .knob: return tr("knob", ["letter": letter(control)])
        case .fader: return tr("board.fader", ["letter": letter(control)])
        case .button: return tr("board.button", ["letter": letter(control)])
        }
    }
}

func nextBoardID(_ added: Int) -> String { "d\(added + 1)" }

// A value that decodes to nil instead of failing the list it is in.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// What a shortcut does on one board: step its profile by step, or with step 0 switch it to profile.
struct HotKeyTarget: Equatable {
    var board: String
    var step = 0
    var profile = 0
}

// One key combination and everything it does, on every board using it: a combination can only be
// registered once, and the same one may switch several boards.
struct HotKeyBinding: Equatable {
    var shortcut: Shortcut
    var targets: [HotKeyTarget]
}

func hotKeyBindings(_ boards: [Board]) -> [HotKeyBinding] {
    var bindings: [HotKeyBinding] = []
    func add(_ shortcut: Shortcut?, _ target: HotKeyTarget) {
        guard let shortcut else { return }
        if let index = bindings.firstIndex(where: { $0.shortcut.sameKeys(shortcut) }) {
            bindings[index].targets.append(target)
        } else {
            bindings.append(HotKeyBinding(shortcut: shortcut, targets: [target]))
        }
    }
    for board in boards where board.enabled {
        add(board.next, HotKeyTarget(board: board.id, step: 1))
        add(board.previous, HotKeyTarget(board: board.id, step: -1))
        for (index, profile) in board.profiles.enumerated() { add(profile.shortcut, HotKeyTarget(board: board.id, profile: index)) }
    }
    return bindings
}

// The other enabled boards a shortcut also switches, by name.
func alsoUsedBy(_ shortcut: Shortcut?, besides id: String, in boards: [Board]) -> [String] {
    guard let shortcut else { return [] }
    return boards.filter { board in
        board.id != id && board.enabled
            && ([board.next, board.previous] + board.profiles.map(\.shortcut)).contains { $0?.sameKeys(shortcut) == true }
    }.map(\.name)
}

// MARK: The SMC-Mixer's controls, by weej's smc.go

func smcControlName(_ control: Int) -> String {
    switch control {
    case 0..<8: return tr("mixer.fader", ["n": control + 1])
    case 8..<16: return tr("mixer.knob", ["n": control - 7])
    default:
        guard let note = buttonNote(control) else { return String(control) }
        if note < 32 {
            let strip = note % 8 + 1
            switch note / 8 {
            case 0: return "R\(strip)"
            case 1: return "S\(strip)"
            case 2: return "M\(strip)"
            default: return tr("smc.square", ["n": strip])
            }
        }
        let names = ["action.play", "action.pause", "smc.record", "action.previous_track", "action.next_track",
                     "smc.bank_left", "smc.bank_right", "smc.up", "smc.down", "smc.left", "smc.right"]
        return smcBottomNotes.firstIndex(of: note).map { tr(names[$0]) } ?? String(control)
    }
}
