import AppKit

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
    case app(String)  // one app's volume, by bundle identifier
}

// Knobs as saved before profiles, each with its own job. Only read, to make the first profile.
struct Knob: Decodable, Equatable {
    var column: Int?
    var target: Target?
}

// Indexed like Setup.columns: each knob's jobs, which all take its position as it turns. A knob past
// the end has none.
struct Profile: Codable, Equatable {
    var name: String
    var jobs: [[Target]] = []
    var shortcut: Shortcut?

    func jobs(of knob: Int) -> [Target] { knob < jobs.count ? jobs[knob] : [] }

    init(name: String, jobs: [[Target]] = [], shortcut: Shortcut? = nil) {
        (self.name, self.jobs, self.shortcut) = (name, jobs, shortcut)
    }

    // Saved so that every older TheeJ still reads the profiles, as one job per knob: the knob's first.
    // "targets" holds that job, or nothing when it is an app, since a version before 1.5.0 fails on the
    // whole profile list at a job it doesn't know, falls back to none, and overwrites them all at its next
    // save. "apps" holds it when it is an app, which is where 1.5.0 looks. "jobs" holds every job, and is
    // only written once a knob has more than one.
    enum CodingKeys: String, CodingKey { case name, targets, shortcut, apps, jobs }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        shortcut = try values.decodeIfPresent(Shortcut.self, forKey: .shortcut)
        if let every = try values.decodeIfPresent([[Target]].self, forKey: .jobs) {
            jobs = every
            return
        }
        var first = try values.decode([Target?].self, forKey: .targets)
        let apps = try values.decodeIfPresent([String?].self, forKey: .apps) ?? []
        for (knob, app) in apps.enumerated() where knob < first.count {
            if let app { first[knob] = .app(app) }
        }
        jobs = first.map { $0.map { [$0] } ?? [] }
    }

    func encode(to encoder: Encoder) throws {
        let first = jobs.map(\.first)
        let apps = first.map { job -> String? in
            if case .app(let id)? = job { return id }
            return nil
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(zip(first, apps).map { $1 == nil ? $0 : nil }, forKey: .targets)
        try values.encodeIfPresent(shortcut, forKey: .shortcut)
        if apps.contains(where: { $0 != nil }) { try values.encode(apps, forKey: .apps) }
        if jobs.contains(where: { $0.count > 1 }) { try values.encode(jobs, forKey: .jobs) }
    }
}

// keyCode is what Carbon registers. key is what that key types with no modifiers, which a menu
// takes as its key equivalent. modifiers holds only ⌃⌥⇧⌘.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var key: String

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
        case 0x20: "Space"
        case 0x0D: "↩"
        case 0x09: "⇥"
        case 0x7F: "⌫"
        default: key.uppercased()
        }
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + name
    }
}

// How soon a knob's job applies, picked in Settings. The raw values are saved, so renaming one resets it.
enum Speed: String, CaseIterable {
    case slow, medium, fast, superFast

    var title: String {
        switch self {
        case .slow: return "Slow (Recommended)"
        case .medium: return "Medium"
        case .fast: return "Fast"
        case .superFast: return "Super fast"
        }
    }

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
    var columns: [Int?] = []
    var profiles = [Profile(name: "Default")]
    var active = 0
    var next: Shortcut?  // from any app, like a profile's own shortcut
    var previous: Shortcut?
    var invert = false
    var showName = false
    var showProfiles = true  // the profiles in the menu bar's menu
    var hideIcon = false
    var icon = IconStyle.mixer
    var speed = Speed.slow

    var profile: Profile {
        get { profiles[active] }
        set { profiles[active] = newValue }
    }

    var mapping: [Int: [Target]] { targets(columns, profile.jobs) }

    // Every app a knob sets the volume of, in any profile.
    var apps: Set<String> {
        Set(profiles.flatMap(\.jobs).joined().compactMap { job in
            if case .app(let id) = job { return id }
            return nil
        })
    }

    // The profile `by` steps away from the active one, wrapping round at either end.
    func stepped(_ by: Int) -> Int { ((active + by) % profiles.count + profiles.count) % profiles.count }

    // JSON strings rather than data, so `defaults read com.zolfer.theej` is readable.
    static func load() -> Setup {
        func decode<T: Decodable>(_ key: String) -> T? {
            prefs.string(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
        }
        var setup = Setup()
        if let profiles: [Profile] = decode("profiles"), !profiles.isEmpty {
            setup.profiles = profiles
            setup.columns = decode("columns") ?? []
        } else if let knobs: [Knob] = decode("knobs") {
            setup.columns = knobs.map(\.column)
            setup.profile.jobs = knobs.map { $0.target.map { [$0] } ?? [] }
        }
        setup.active = min(max(prefs.integer(forKey: "profile"), 0), setup.profiles.count - 1)
        setup.next = decode("nextProfile")
        setup.previous = decode("previousProfile")
        setup.invert = prefs.bool(forKey: "invertKnobs")
        setup.showName = prefs.bool(forKey: "showProfileName")
        setup.showProfiles = prefs.object(forKey: "showProfileList") as? Bool ?? true
        setup.hideIcon = prefs.bool(forKey: "hideMenuBarIcon")
        setup.icon = IconStyle(rawValue: prefs.string(forKey: "menuBarIcon") ?? "") ?? .mixer
        setup.speed = Speed(rawValue: prefs.string(forKey: "speed") ?? "") ?? .slow
        return setup
    }

    func save() {
        func encode<T: Encodable>(_ value: T, _ key: String) {
            guard let json = try? JSONEncoder().encode(value) else { return }
            prefs.set(String(decoding: json, as: UTF8.self), forKey: key)
        }
        encode(columns, "columns")
        encode(profiles, "profiles")
        prefs.set(active, forKey: "profile")
        encode(next, "nextProfile")
        encode(previous, "previousProfile")
        prefs.set(invert, forKey: "invertKnobs")
        prefs.set(showName, forKey: "showProfileName")
        prefs.set(showProfiles, forKey: "showProfileList")
        prefs.set(hideIcon, forKey: "hideMenuBarIcon")
        prefs.set(icon.rawValue, forKey: "menuBarIcon")
        prefs.set(speed.rawValue, forKey: "speed")
    }
}

// A loop, not Dictionary(uniqueKeysWithValues:), which traps on a duplicate column.
func targets(_ columns: [Int?], _ jobs: [[Target]]) -> [Int: [Target]] {
    var result: [Int: [Target]] = [:]
    for (column, jobs) in zip(columns, jobs) {
        if let column, !jobs.isEmpty { result[column] = jobs }
    }
    return result
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
    case .app: return 500  // all the same: Settings lists them by name
    }
}

// The status lines follow the knobs, A first, which is not the order of the serial columns driving
// them. lastIndex, since the last knob on a column is the one targets() keeps.
func ordered(_ mapping: [Int: [Target]], by columns: [Int?]) -> [(key: Int, value: [Target])] {
    mapping.sorted { (columns.lastIndex(of: $0.key) ?? 0) < (columns.lastIndex(of: $1.key) ?? 0) }
}

// A knob's jobs on one line, for Settings and the startup log.
func title(_ jobs: [Target]) -> String {
    jobs.isEmpty ? title(nil) : jobs.map { title($0) }.joined(separator: ", ")
}

func title(_ target: Target?) -> String {
    switch target {
    case nil: return "Nothing"
    case .master?: return "Master volume"
    case .microphone?: return "Microphone volume"
    case .builtinBrightness?: return "Built-in display brightness"
    case .builtinContrast?: return "Built-in display contrast"
    case .nightShift?: return "Night Shift warmth"
    case .brightness(let ordinal)?: return "Screen \(ordinal + 1) brightness"
    case .contrast(let ordinal)?: return "Screen \(ordinal + 1) contrast"
    case .builtinKeyboard?: return "Built-in keyboard backlight"
    case .externalKeyboard?: return "External keyboard backlight"
    case .app(let id)?: return appName(id)
    }
}

func section(_ target: Target) -> String {
    ["Volume", "Brightness", "Contrast", "Night Shift", "Keyboard backlight", "Apps"][rank(target) / 100]
}

// A job's name under its section's header, which says the rest of title().
func shortTitle(_ target: Target) -> String {
    switch target {
    case .master, .microphone: return title(target)
    case .builtinBrightness, .builtinContrast: return "Built-in display"
    case .brightness(let ordinal), .contrast(let ordinal): return "Screen \(ordinal + 1)"
    case .nightShift: return "Warmth"
    case .builtinKeyboard: return "Built-in"
    case .externalKeyboard: return "External"
    case .app: return title(target)
    }
}

// A profile name cut to fit where a long one would push other things out: the menu bar, a menu, a popup.
func clipped(_ name: String, to limit: Int) -> String {
    name.count > limit ? name.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : name
}

func letter(_ index: Int) -> String { String(Character(UnicodeScalar(UInt8(65 + index)))) }
