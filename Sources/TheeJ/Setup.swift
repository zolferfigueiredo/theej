import Foundation
#if canImport(AppKit)
import AppKit
#endif

// The case names are the JSON keys of saved profiles, so renaming one loses that knob's job.
enum Target: Hashable, Codable {
    case master
    case microphone
    case builtinBrightness
    case builtinContrast
    case nightShift
    // Index into the external displays sorted left to right, so 0 is the leftmost.
    case brightness(Int)
    case contrast(Int)
    case builtinKeyboard
    case externalKeyboard
    case zoom  // the whole screen's magnification
    case app(String)  // one app's volume, by bundle identifier
}

// Knobs as saved before profiles, each with its own job. Only read, to make the first board.
struct Knob: Decodable, Equatable {
    var column: Int?
    var target: Target?
}

// Indexed like Board.controls: each control's jobs, which all take its position as it turns, and each
// button's actions by its key (Board.buttonKey). A control past the end has none.
struct Profile: Codable, Equatable {
    var name: String
    var jobs: [[Target]] = []
    var shortcut: Shortcut?
    var buttons: [Int: [String]] = [:]

    func jobs(of control: Int) -> [Target] { control < jobs.count ? jobs[control] : [] }

    // Controls past the end have no jobs, so a profile padded with empty ones is the same profile. Apply
    // in Settings stays off after a job is ticked and unticked.
    static func == (a: Profile, b: Profile) -> Bool {
        a.name == b.name && a.shortcut == b.shortcut && a.buttons == b.buttons
            && (0..<max(a.jobs.count, b.jobs.count)).allSatisfy { a.jobs(of: $0) == b.jobs(of: $0) }
    }

    init(name: String, jobs: [[Target]] = [], shortcut: Shortcut? = nil, buttons: [Int: [String]] = [:]) {
        (self.name, self.jobs, self.shortcut, self.buttons) = (name, jobs, shortcut, buttons)
    }

    // A board's profiles keep every job in "jobs" and the buttons' actions in "buttons", by key, as WeeJ
    // does. 1.8 and before saved one job per knob in "targets", an app's in "apps", every job in "jobs" once
    // a knob had several, and zoom in "zoom": those are read once, to make the first board.
    enum CodingKeys: String, CodingKey { case name, targets, shortcut, apps, jobs, zoom, buttons }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        shortcut = try? values.decodeIfPresent(Shortcut.self, forKey: .shortcut)
        // A job this version doesn't know is dropped, not the whole profile with it.
        if let every = try? values.decodeIfPresent([[Lossy<Target>]].self, forKey: .jobs) {
            jobs = every.map { $0.compactMap(\.value) }
        } else {
            var first = try values.decode([Target?].self, forKey: .targets)
            let apps = try values.decodeIfPresent([String?].self, forKey: .apps) ?? []
            for (knob, app) in apps.enumerated() where knob < first.count {
                if let app { first[knob] = .app(app) }
            }
            jobs = first.map { $0.map { [$0] } ?? [] }
        }
        for knob in (try? values.decodeIfPresent([Int].self, forKey: .zoom)) ?? [] where jobs.indices.contains(knob) {
            jobs[knob].append(.zoom)
        }
        // A bad entry goes on its own: a key that is no button id, or an action this version doesn't know.
        for (key, list) in (try? values.decodeIfPresent([String: Actions].self, forKey: .buttons)) ?? [:] {
            guard let id = Int(key), (0...255).contains(id) else { continue }
            var kept: [String] = []
            for action in list.actions where validAction(action) && !kept.contains(action) { kept.append(action) }
            if !kept.isEmpty { buttons[id] = kept }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(shortcut, forKey: .shortcut)
        try values.encode(jobs, forKey: .jobs)
        let buttons = Dictionary(uniqueKeysWithValues: self.buttons.filter { !$0.value.isEmpty }.map { (String($0.key), $0.value) })
        try values.encode(buttons, forKey: .buttons)
    }

    // A button's actions, or a single one, as WeeJ once saved them.
    private struct Actions: Decodable {
        let actions: [String]

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            actions = (try? value.decode([String].self)) ?? (try? value.decode(String.self)).map { [$0] } ?? []
        }
    }
}

// keyCode is what Carbon registers. key is what that key types with no modifiers, which a menu
// takes as its key equivalent. modifiers holds only ⌃⌥⇧⌘.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var key: String

    // The same keys, whatever the layout types with them.
    func sameKeys(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
}

#if canImport(AppKit)
extension Shortcut {
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var label: String {
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let scalar = key.unicodeScalars.first?.value ?? 0
        // AppKit types the keys with no character as private use scalars from 0xF700.
        let name = switch scalar {
        case 0xF704...0xF726: "F\(scalar - 0xF703)"
        case 0xF700: "↑"
        case 0xF701: "↓"
        case 0xF702: "←"
        case 0xF703: "→"
        case 0x20: tr("space")
        case 0x0D: "↩"
        case 0x09: "⇥"
        case 0x7F: "⌫"
        default: key.uppercased()
        }
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + name
    }
}
#else
// Linux, where only the tests run, has no apps to name.
func appName(_ id: String) -> String { id }
#endif

// How soon a knob's job applies, picked in Settings. The raw values are saved, so renaming one resets it.
enum Speed: String, CaseIterable, Codable {
    case slow, medium, fast, superFast

    var title: String { tr("speed.\(rawValue)") }

    // ponytail: every job but the volumes applies once a knob has been still this long; each movement
    // restarts the wait. It must stay above ~110ms, the longest wiper dropout on this board (a moving
    // pot briefly reads its neighbour's value), or a dropout reaches the panel as a flash.
    var settle: Double {
        switch self {
        case .slow: return 0.3
        case .medium: return 0.22
        case .fast: return 0.18
        case .superFast: return 0.15
        }
    }
}

// The domain is the bundle identifier, com.zolfer.theej. A suite with that name is refused, since
// it is the app's own domain.
let prefs = UserDefaults.standard

struct Setup: Equatable {
    var boards: [Board] = []
    var added = 0  // every board ever added, so an id is never given out again
    var showName = false
    var showProfiles = true  // each board's profiles in the menu bar's menu
    var hideIcon = false
    var icon = IconStyle.mixer

    func board(_ id: String) -> Board? { boards.first { $0.id == id } }

    func index(of id: String) -> Int? { boards.firstIndex { $0.id == id } }

    var apps: Set<String> { Set(boards.flatMap(\.apps)) }

    // JSON strings rather than data, so `defaults read com.zolfer.theej` is readable. The keys from before
    // boards (columns, profiles, knobs, profile, nextProfile, previousProfile, invertKnobs, speed) are read
    // once, to make the first board, and never written, so TheeJ 1.8 still finds its own after a downgrade.
    static func load(from defaults: UserDefaults = prefs) -> Setup {
        var setup = Setup()
        if let json = defaults.string(forKey: "boards"),
           let boards = try? JSONDecoder().decode([Lossy<Board>].self, from: Data(json.utf8)) {
            setup.boards = boards.compactMap(\.value)
            setup.added = defaults.integer(forKey: "boardsAdded")
            for board in setup.boards where board.id.hasPrefix("d") {
                setup.added = max(setup.added, Int(board.id.dropFirst()) ?? 0)
            }
            var seen: Set<String> = []
            for index in setup.boards.indices where setup.boards[index].id.isEmpty || !seen.insert(setup.boards[index].id).inserted {
                setup.boards[index].id = nextBoardID(setup.added)
                setup.added += 1
            }
        } else if let board = legacyBoard(defaults) {
            setup.boards = [board]
            setup.added = 1
        }
        setup.showName = defaults.bool(forKey: "showProfileName")
        setup.showProfiles = defaults.object(forKey: "showProfileList") as? Bool ?? true
        setup.hideIcon = defaults.bool(forKey: "hideMenuBarIcon")
        setup.icon = IconStyle(rawValue: defaults.string(forKey: "menuBarIcon") ?? "") ?? .mixer
        if defaults.string(forKey: "boards") == nil, !setup.boards.isEmpty { setup.save(to: defaults) }
        return setup
    }

    func save(to defaults: UserDefaults = prefs) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let json = try? encoder.encode(boards) { defaults.set(String(decoding: json, as: UTF8.self), forKey: "boards") }
        defaults.set(added, forKey: "boardsAdded")
        defaults.set(showName, forKey: "showProfileName")
        defaults.set(showProfiles, forKey: "showProfileList")
        defaults.set(hideIcon, forKey: "hideMenuBarIcon")
        defaults.set(icon.rawValue, forKey: "menuBarIcon")
    }
}

// The board TheeJ read before boards, as board d1: its knobs, profiles, shortcuts and speed. 1.8 read a
// knob as 1 - raw, which Invert undid, so each knob is reversed unless Invert was on.
func legacyBoard(_ defaults: UserDefaults) -> Board? {
    func decode<T: Decodable>(_ key: String) -> T? {
        defaults.string(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
    var columns: [Int?] = decode("columns") ?? []
    var profiles: [Profile] = decode("profiles") ?? []
    if profiles.isEmpty, let knobs: [Knob] = decode("knobs") {
        columns = knobs.map(\.column)
        profiles = [Profile(name: tr("default_profile"), jobs: knobs.map { $0.target.map { [$0] } ?? [] })]
    }
    let count = max(columns.count, profiles.map(\.jobs.count).max() ?? 0)
    guard count > 0 else { return nil }
    let invert = defaults.bool(forKey: "invertKnobs")
    var board = Board(id: nextBoardID(0), name: tr("device.type.diy"), type: .diy)
    board.controls = (0..<count).map { Control(kind: .knob, input: $0 < columns.count ? columns[$0] : nil, reverse: !invert) }
    board.profiles = profiles.isEmpty ? [board.newProfile(tr("default_profile"))] : profiles
    for index in board.profiles.indices { board.profiles[index].jobs = board.fitted(board.profiles[index].jobs) }
    board.active = min(max(defaults.integer(forKey: "profile"), 0), board.profiles.count - 1)
    board.next = decode("nextProfile")
    board.previous = decode("previousProfile")
    board.speed = Speed(rawValue: defaults.string(forKey: "speed") ?? "") ?? .slow
    board.list = true  // the rows 1.8 showed
    return board
}

// The order of the jobs in a knob's popup in Settings. Each hundred is a section there, under the
// header section() gives it. Screens count left to right within theirs, and activeDisplays() stops
// at 16, so they cannot reach the next section.
func rank(_ target: Target) -> Int {
    switch target {
    case .master: return 0
    case .microphone: return 1
    case .builtinBrightness: return 100
    case .brightness(let ordinal): return 101 + ordinal
    case .builtinContrast: return 200
    case .contrast(let ordinal): return 201 + ordinal
    case .nightShift: return 300
    case .builtinKeyboard: return 400
    case .externalKeyboard: return 401
    case .zoom: return 500
    case .app: return 600  // all the same: Settings lists them by name
    }
}

// A knob's jobs on one line, for Settings and the startup log.
func title(_ jobs: [Target]) -> String {
    jobs.isEmpty ? title(nil) : jobs.map { title($0) }.joined(separator: ", ")
}

func title(_ target: Target?) -> String {
    switch target {
    case nil: return tr("job.nothing")
    case .master?: return tr("job.master")
    case .microphone?: return tr("job.microphone")
    case .builtinBrightness?: return tr("job.builtin_brightness")
    case .builtinContrast?: return tr("job.builtin_contrast")
    case .nightShift?: return tr("job.night_shift")
    case .brightness(let ordinal)?: return tr("job.brightness", ["n": ordinal + 1])
    case .contrast(let ordinal)?: return tr("job.contrast", ["n": ordinal + 1])
    case .builtinKeyboard?: return tr("job.builtin_keyboard")
    case .externalKeyboard?: return tr("job.external_keyboard")
    case .zoom?: return tr("job.zoom")
    case .app(let id)?: return appName(id)
    }
}

func section(_ target: Target) -> String {
    tr("section." + ["volume", "brightness", "contrast", "night_shift", "keyboard", "zoom", "apps"][rank(target) / 100])
}

// A job's name under its section's header, which says the rest of title().
func shortTitle(_ target: Target) -> String {
    switch target {
    case .master, .microphone, .zoom: return title(target)
    case .builtinBrightness, .builtinContrast: return tr("short.builtin_display")
    case .brightness(let ordinal), .contrast(let ordinal): return tr("short.screen", ["n": ordinal + 1])
    case .nightShift: return tr("short.warmth")
    case .builtinKeyboard: return tr("short.builtin")
    case .externalKeyboard: return tr("short.external")
    case .app: return title(target)
    }
}

// A profile name cut to fit where a long one would push other things out: the menu bar, a menu, a popup.
func clipped(_ name: String, to limit: Int) -> String {
    name.count > limit ? name.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : name
}

// A to Z, then A2 to Z2, A3 and on.
func letter(_ index: Int) -> String {
    String(Character(UnicodeScalar(UInt8(65 + index % 26)))) + (index < 26 ? "" : String(index / 26 + 1))
}
