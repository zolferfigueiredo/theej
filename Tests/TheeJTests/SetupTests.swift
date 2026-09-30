import AppKit
import Testing
@testable import TheeJ

// Knob A to E arrive on serial columns 0, 3, 2, 4 and 1.
private let columns: [Int?] = [0, 3, 2, 4, 1]
private let jobs: [Target?] = [.master, .brightness(0), .brightness(1), nil, .builtinBrightness]

@Test func percentRoundsAndClamps() {
    #expect(percent(0) == 0)
    #expect(percent(1) == 100)
    #expect(percent(-0.5) == 0)
    #expect(percent(1.5) == 100)
    #expect(percent(0.355) == 36)
    #expect(percent(0.004) == 0)
}

// A knob with no job maps to nothing, and so does one past the end of the profile's jobs.
@Test func knobsMapToSerialColumns() {
    #expect(targets(columns, jobs) == [0: .master, 1: .builtinBrightness, 3: .brightness(0), 2: .brightness(1)])
    #expect(targets(columns, [.master]) == [0: .master])
}

// Menu order is knob order, A to E, which is not the serial column order.
@Test func menuOrder() {
    #expect(ordered(targets(columns, jobs), by: columns).map(\.key) == [0, 3, 2, 1])
    #expect(ordered(targets(columns, jobs), by: columns).map(\.value) == [.master, .brightness(0), .brightness(1), .builtinBrightness])
}

// The rank bands must stay distinct as target kinds are added.
private let every: [Target] = [.master, .microphone, .builtinBrightness, .builtinContrast, .nightShift]
    + (0..<16).flatMap { [.brightness($0), .contrast($0)] } + [.builtinKeyboard, .externalKeyboard]

@Test func everyTargetHasItsOwnRank() {
    #expect(Set(every.map(rank)).count == every.count)
}

// Two jobs in one section must not read the same, and every rank band needs a header.
@Test func shortTitlesAreDistinctWithinASection() {
    #expect(Set(every.map { section($0) + shortTitle($0) }).count == every.count)
}

@Test func targetsSurviveSaving() throws {
    #expect(try JSONDecoder().decode([Target].self, from: JSONEncoder().encode(every)) == every)
}

// Knobs saved before profiles still load, to become the first profile.
@Test func knobsSavedBeforeProfilesStillLoad() throws {
    let saved = #"[{"target":{"master":{}},"column":0},{"target":{"brightness":{"_0":0}},"column":3},"#
        + #"{"target":{"brightness":{"_0":1}},"column":2},{"column":4},{"target":{"builtinBrightness":{}},"column":1}]"#
    #expect(try JSONDecoder().decode([Knob].self, from: Data(saved.utf8)) == zip(columns, jobs).map { Knob(column: $0, target: $1) })
}

@Test func longNamesAreClipped() {
    #expect(clipped("Default", to: 20) == "Default")
    #expect(clipped("Default dasdas asd asdas asd asdas", to: 20) == "Default dasdas asd…")
    #expect(clipped(String(repeating: "a", count: 30), to: 20).count == 20)
}

// Next from the last profile is the first, and previous from the first is the last.
@Test func steppingThroughProfilesWrapsRound() {
    var setup = Setup(profiles: [Profile(name: "A"), Profile(name: "B"), Profile(name: "C")])
    #expect(setup.stepped(1) == 1 && setup.stepped(-1) == 2)
    setup.active = 2
    #expect(setup.stepped(1) == 0 && setup.stepped(-1) == 1)
}

@Test func profilesAndShortcutsSurviveSaving() throws {
    let games = [Profile(name: "Games", targets: jobs, shortcut: Shortcut(
        keyCode: 18, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "1"))]
    #expect(try JSONDecoder().decode([Profile].self, from: JSONEncoder().encode(games)) == games)
    #expect(games[0].shortcut?.label == "⌃⌥1")
    let f1 = Shortcut(keyCode: 122, modifiers: NSEvent.ModifierFlags.command.rawValue, key: "\u{F704}")
    #expect(f1.label == "⌘F1")
}
