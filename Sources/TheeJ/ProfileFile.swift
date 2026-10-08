import Foundation

// Export writes a profile as WeeJ does, so either app reads the other's file: the jobs by control in WeeJ's
// spelling, the buttons by key, and the type of board they were set on. WeeJ refuses a file holding a job
// kind it doesn't know, so the jobs TheeJ reads back go under "theej", which WeeJ passes over, and
// "platform" says the apps and keys in the file are a Mac's.
let profileFileKind = "weej.profile"

private struct FileJob: Codable {
    var kind: String
    var screen: Int?
    var exe: String?  // a Windows app's file name
}

private struct ExportFile: Encodable {
    let kind = profileFileKind
    let version = 1
    let type: BoardType
    let platform = "macos"
    let profile: Body
    let theej: Jobs

    struct Body: Encodable {
        let name: String
        let jobs: [[FileJob]]
        let buttons: [String: [String]]
    }

    struct Jobs: Encodable {
        let jobs: [[Target]]
    }
}

private struct ImportFile: Decodable {
    let kind: String
    let type: String?
    let platform: String?
    let profile: Profile  // its name and buttons: Profile reads only TheeJ's spelling of jobs
    let jobs: [[Lossy<FileJob>]]
    let theej: [[Lossy<Target>]]?

    enum CodingKeys: String, CodingKey { case kind, type, platform, profile, theej }

    private struct Jobs<T: Decodable>: Decodable {
        let jobs: T
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        type = try? values.decode(String.self, forKey: .type)
        platform = try? values.decode(String.self, forKey: .platform)
        profile = try values.decode(Profile.self, forKey: .profile)
        jobs = (try? values.decode(Jobs<[[Lossy<FileJob>]]>.self, forKey: .profile))?.jobs ?? []
        theej = (try? values.decode(Jobs<[[Lossy<Target>]]>.self, forKey: .theej))?.jobs
    }
}

private func fileJob(_ job: Target) -> FileJob? {
    switch job {
    case .master: return FileJob(kind: "master")
    case .microphone: return FileJob(kind: "microphone")
    case .builtinBrightness: return FileJob(kind: "builtinBrightness")
    case .brightness(let screen): return FileJob(kind: "brightness", screen: screen)
    case .contrast(let screen): return FileJob(kind: "contrast", screen: screen)
    case .nightShift: return FileJob(kind: "nightLight")
    case .externalKeyboard: return FileJob(kind: "externalKeyboard")
    case .zoom: return FileJob(kind: "zoom")
    case .builtinContrast, .builtinKeyboard, .app: return nil
    }
}

// activeDisplays() lists 16 screens at most, and rank() needs a screen below 99 to stay in its section.
private func screen(_ index: Int?) -> Int? { index.flatMap { (0..<16).contains($0) ? $0 : nil } }

private func target(_ job: FileJob) -> Target? {
    switch job.kind {
    case "master": return .master
    case "microphone": return .microphone
    case "builtinBrightness": return .builtinBrightness
    case "brightness": return screen(job.screen).map(Target.brightness)
    case "contrast": return screen(job.screen).map(Target.contrast)
    case "nightLight": return .nightShift
    case "externalKeyboard": return .externalKeyboard
    case "zoom": return .zoom
    default: return nil
    }
}

private func importable(_ job: Target) -> Bool {
    switch job {
    case .brightness(let index), .contrast(let index): return screen(index) != nil
    case .app(let id): return !id.isEmpty
    default: return true
    }
}

func profileFile(_ profile: Profile, of board: Board) -> Data? {
    let jobs = board.fitted(profile.jobs)
    let buttons = Dictionary(uniqueKeysWithValues: profile.buttons.filter { !$0.value.isEmpty }.map { (String($0.key), $0.value) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try? encoder.encode(ExportFile(type: board.type, profile: .init(name: profile.name, jobs: jobs.map { $0.compactMap(fileJob) },
                                                                         buttons: buttons), theej: .init(jobs: jobs)))
}

// A file Export wrote, or deej's config.yaml, as a new profile of board, and what it holds that has no place
// on that board or on a Mac. nil for a file that is neither.
func importedProfile(_ data: Data, for board: Board) -> (profile: Profile, skipped: [String])? {
    if let file = try? JSONDecoder().decode(ImportFile.self, from: data), file.kind == profileFileKind {
        return fileProfile(file, for: board)
    }
    return deejProfile(data, for: board)
}

// Jobs go by control, as in WeeJ, and the buttons only come from a board of the same type, which keys them
// the same way.
private func fileProfile(_ file: ImportFile, for board: Board) -> (Profile, [String]) {
    var profile = board.newProfile(file.profile.name)
    var skipped: [String] = []
    let mac = file.platform == "macos"
    for control in profile.jobs.indices {
        if mac, let jobs = file.theej {
            profile.jobs[control] = control < jobs.count ? jobs[control].compactMap(\.value).filter(importable) : []
            continue
        }
        for job in control < file.jobs.count ? file.jobs[control].compactMap(\.value) : [] {
            if let target = target(job) {
                if !profile.jobs[control].contains(target) { profile.jobs[control].append(target) }
            } else {
                let names = ["systemSounds": "job.system_sounds", "focusedApp": "job.focused_app", "otherApps": "job.other_apps"]
                skipped.append(job.exe ?? names[job.kind].map { tr($0) } ?? job.kind)
            }
        }
    }
    guard file.type == board.type.rawValue else { return (profile, skipped) }
    profile.buttons = file.profile.buttons
    guard !mac else { return (profile, skipped) }
    // Another system names its apps and keys its own way.
    let kinds = ["open:": "action.open_app", "close:": "action.close_app", "keys:": "action.keys"]
    for key in profile.buttons.keys.sorted() {
        let name = board.control(ofKey: key).map(board.controlName) ?? String(key)
        for action in profile.buttons[key] ?? [] {
            guard let kind = kinds.first(where: { action.hasPrefix($0.key) }) else { continue }
            skipped.append("\(name): \(tr(kind.value))")
        }
        profile.buttons[key]?.removeAll { action in kinds.keys.contains { action.hasPrefix($0) } }
        if profile.buttons[key]?.isEmpty == true { profile.buttons[key] = nil }
    }
    return (profile, skipped)
}

// deej's slider_mapping, as WeeJ imports it: each slider's master volume, mic and screen brightness go to the
// knob or fader on that input of a DIY board, or at that place on any other. Its apps are Windows' or Linux's
// process names, which name no Mac app, so they are skipped with the rest.
private func deejProfile(_ data: Data, for board: Board) -> (Profile, [String])? {
    var text = String(decoding: data, as: UTF8.self)
    if text.first == "\u{FEFF}" { text.removeFirst() }
    guard let sliders = deejSliders(text) else { return nil }
    var profile = board.newProfile("deej")
    var skipped: [String] = []
    for (slider, entries) in sliders {
        guard let input = Int(slider) else {
            skipped.append(slider)
            continue
        }
        var jobs: [Target] = []
        for entry in entries {
            if let job = deejJob(entry) {
                if !jobs.contains(job) { jobs.append(job) }
            } else {
                skipped.append(entry)
            }
        }
        let control = board.controls.indices.first { index in
            board.controls[index].kind != .button && (board.type == .diy ? board.controls[index].input == input : index == input)
        }
        guard let control else {
            skipped.append("slider \(input)")
            continue
        }
        for job in jobs where !profile.jobs[control].contains(job) { profile.jobs[control].append(job) }
    }
    var seen: Set<String> = []
    return (profile, skipped.filter { seen.insert($0.lowercased()).inserted })
}

private func deejJob(_ entry: String) -> Target? {
    let name = entry.lowercased()
    if name == "master" { return .master }
    if name == "mic" { return .microphone }
    // "monitor 1 (brightness)", screen 1 being the first
    guard name.hasPrefix("monitor"), name.hasSuffix("(brightness)") else { return nil }
    let middle = name.dropFirst(7).dropLast(12)
    let number = middle.trimmingCharacters(in: .whitespaces)
    guard middle.first?.isWhitespace == true, !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }),
          let index = Int(number).flatMap({ screen($0 - 1) }) else { return nil }
    return .brightness(index)
}

// slider_mapping's sliders in the file's order, each with its entries, or nil for a file without one. Only
// the YAML deej's config is written in: "0: master", "1:" over "- chrome.exe" lines, or "2: [a, b]", with
// comments and quotes.
func deejSliders(_ yaml: String) -> [(slider: String, entries: [String])]? {
    var sliders: [(slider: String, entries: [String])] = []
    var inMapping: Bool?  // nil until slider_mapping turns up
    for raw in yaml.split(whereSeparator: \.isNewline) {
        let line = uncommented(raw)
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        guard line.first?.isWhitespace == true else {
            inMapping = text.hasPrefix("slider_mapping:") ? true : inMapping.map { _ in false }
            continue
        }
        guard inMapping == true else { continue }
        if text.hasPrefix("- ") || text == "-" {
            if !sliders.isEmpty { sliders[sliders.count - 1].entries.append(unquoted(text.dropFirst())) }
        } else if let colon = text.firstIndex(of: ":") {
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let entries = value.hasPrefix("[") && value.hasSuffix("]")
                ? value.dropFirst().dropLast().split(separator: ",").map(unquoted) : [unquoted(value)]
            sliders.append((unquoted(text[..<colon]), entries.filter { !$0.isEmpty }))
        }
    }
    return inMapping == nil ? nil : sliders
}

// A # starts a comment at the start of a line or after a space.
private func uncommented(_ line: Substring) -> Substring {
    var previous: Character = " "
    for index in line.indices {
        if line[index] == "#", previous.isWhitespace { return line[..<index] }
        previous = line[index]
    }
    return line
}

private func unquoted<S: StringProtocol>(_ text: S) -> String {
    let text = text.trimmingCharacters(in: .whitespaces)
    if text.count >= 2, let quote = text.first, quote == text.last, quote == "\"" || quote == "'" {
        return String(text.dropFirst().dropLast())
    }
    return text
}
