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
}

// Knobs as saved before profiles, each with its own job. Only read, to make the first profile.
struct Knob: Decodable, Equatable {
    var column: Int?
    var target: Target?
}

// Indexed like Setup.columns. A knob past the end of targets does nothing.
struct Profile: Codable, Equatable {
    var name: String
    var targets: [Target?] = []
    var shortcut: Shortcut?

    func target(_ knob: Int) -> Target? { knob < targets.count ? targets[knob] : nil }
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

    var profile: Profile {
        get { profiles[active] }
        set { profiles[active] = newValue }
    }

    var mapping: [Int: Target] { targets(columns, profile.targets) }

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
            setup.profile.targets = knobs.map(\.target)
        }
        setup.active = min(max(prefs.integer(forKey: "profile"), 0), setup.profiles.count - 1)
        setup.next = decode("nextProfile")
        setup.previous = decode("previousProfile")
        setup.invert = prefs.bool(forKey: "invertKnobs")
        setup.showName = prefs.bool(forKey: "showProfileName")
        setup.showProfiles = prefs.object(forKey: "showProfileList") as? Bool ?? true
        setup.hideIcon = prefs.bool(forKey: "hideMenuBarIcon")
        setup.icon = IconStyle(rawValue: prefs.string(forKey: "menuBarIcon") ?? "") ?? .mixer
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
    }
}

// A loop, not Dictionary(uniqueKeysWithValues:), which traps on a duplicate column.
func targets(_ columns: [Int?], _ jobs: [Target?]) -> [Int: Target] {
    var result: [Int: Target] = [:]
    for (column, target) in zip(columns, jobs) {
        if let column, let target { result[column] = target }
    }
    return result
}

// The one order for the jobs in Settings and the status lines, which is not the order of the serial
// columns driving them. Each hundred is a group that Settings separates. Monitors count left to right
// within theirs, and activeDisplays() stops at 16, so they cannot reach the next group.
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
    }
}

func ordered(_ mapping: [Int: Target]) -> [(key: Int, value: Target)] {
    mapping.sorted { (rank($0.value), $0.key) < (rank($1.value), $1.key) }
}

func title(_ target: Target?) -> String {
    switch target {
    case nil: return "Nothing"
    case .master?: return "Master volume"
    case .microphone?: return "Microphone volume"
    case .builtinBrightness?: return "Built-in display brightness"
    case .builtinContrast?: return "Built-in display contrast"
    case .nightShift?: return "Night Shift warmth"
    case .brightness(let ordinal)?: return "Monitor \(ordinal + 1) brightness"
    case .contrast(let ordinal)?: return "Monitor \(ordinal + 1) contrast"
    case .builtinKeyboard?: return "Built-in keyboard backlight"
    case .externalKeyboard?: return "External keyboard backlight"
    }
}

func letter(_ index: Int) -> String { String(Character(UnicodeScalar(UInt8(65 + index)))) }
