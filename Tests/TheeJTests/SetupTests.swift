import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import TheeJ

// Knob A to E arrive on serial columns 0, 3, 2, 4 and 1.
private let columns: [Int?] = [0, 3, 2, 4, 1]
private let jobs: [[Target]] = [[.master], [.brightness(0)], [.brightness(1)], [], [.builtinBrightness]]
// The strings expected below are English, whatever language this Mac uses.
private let english: Void = UserDefaults.standard.set("en", forKey: "language")

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
    #expect(targets(columns, jobs) == [0: [.master], 1: [.builtinBrightness], 3: [.brightness(0)], 2: [.brightness(1)]])
    #expect(targets(columns, [[.master]]) == [0: [.master]])
    // One knob can do several jobs, of any kind.
    #expect(targets(columns, [[.brightness(0), .brightness(1), .app("com.apple.Music")]])
        == [0: [.brightness(0), .brightness(1), .app("com.apple.Music")]])
}

// Menu order is knob order, A to E, which is not the serial column order.
@Test func menuOrder() {
    #expect(ordered(targets(columns, jobs), by: columns).map(\.key) == [0, 3, 2, 1])
    #expect(ordered(targets(columns, jobs), by: columns).map(\.value) == [[.master], [.brightness(0)], [.brightness(1)], [.builtinBrightness]])
}

// The rank bands must stay distinct as target kinds are added.
private let every: [Target] = [.master, .microphone, .builtinBrightness, .builtinContrast, .nightShift]
    + (0..<16).flatMap { [.brightness($0), .contrast($0)] } + [.builtinKeyboard, .externalKeyboard, .app("com.apple.Music")]

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
    #expect(try JSONDecoder().decode([Knob].self, from: Data(saved.utf8)) == zip(columns, jobs).map { Knob(column: $0, target: $1.first) })
}

// What a TheeJ from before app volumes reads: only the jobs it knew, and it fails on any other.
private enum OldTarget: Decodable, Equatable { case master }
private struct OldProfile: Decodable, Equatable {
    var name: String
    var targets: [OldTarget?]
}

// An app job is saved apart from the others, so an older TheeJ still reads every profile, with that
// knob doing nothing, instead of failing on the list and overwriting it.
@Test func appJobsAreSavedWhereOlderVersionsDoNotLook() throws {
    let music = [Profile(name: "Music", jobs: [[.master], [.app("com.spotify.client")], []])]
    let saved = try JSONEncoder().encode(music)
    #expect(try JSONDecoder().decode([Profile].self, from: saved) == music)
    #expect(try JSONDecoder().decode([OldProfile].self, from: saved) == [OldProfile(name: "Music", targets: [.master, nil, nil])])
    let before = #"[{"name":"Default","targets":[{"master":{}},null]}]"#
    #expect(try JSONDecoder().decode([Profile].self, from: Data(before.utf8)) == [Profile(name: "Default", jobs: [[.master], []])])
    #expect(Setup(profiles: music + [Profile(name: "Calls", jobs: [[.app("us.zoom.xos")]])]).apps == ["com.spotify.client", "us.zoom.xos"])
}

// A knob with several jobs is saved so that older versions read its first one: a plain job where
// versions before app volumes look, an app where 1.5.0 looks. This version reads them all back.
@Test func severalJobsPerKnobAreSavedSoOlderVersionsReadTheFirst() throws {
    _ = english
    let both = [Profile(name: "Desk", jobs: [[.master, .app("com.apple.Music")], [.app("com.google.Chrome"), .master], []])]
    let saved = try JSONEncoder().encode(both)
    #expect(try JSONDecoder().decode([Profile].self, from: saved) == both)
    #expect(try JSONDecoder().decode([OldProfile].self, from: saved) == [OldProfile(name: "Desk", targets: [.master, nil, nil])])
    let json = try #require(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
    // Each item cast on its own: Linux reads a JSON null as NSNull, which [String?] doesn't take.
    #expect((json[0]["apps"] as? [Any])?.map { $0 as? String } == [nil, "com.google.Chrome", nil])
    // With one job per knob nothing new is written, so what is saved stays as it was.
    let plain = try JSONEncoder().encode([Profile(name: "Default", jobs: [[.master], []])])
    #expect(try #require(JSONSerialization.jsonObject(with: plain) as? [[String: Any]])[0]["jobs"] == nil)
    #expect(title([.master, .app("no.such.thing")]) == "Master volume, no.such.thing" && title([Target]()) == "Nothing")
}

#if canImport(AppKit)
// A helper belongs to the app that answers for it, which keeps Chrome Canary out of Chrome's knob.
@Test func audioProcessesBelongToTheirApp() {
    #expect(belongs(bundle: "com.google.Chrome", owner: "com.google.Chrome", to: "com.google.Chrome"))
    #expect(belongs(bundle: "com.google.Chrome.helper", owner: "com.google.Chrome", to: "com.google.Chrome"))
    #expect(belongs(bundle: "com.apple.WebKit.GPU", owner: "com.apple.Safari", to: "com.apple.Safari"))
    #expect(belongs(bundle: "com.google.Chrome.helper", owner: nil, to: "com.google.Chrome"))
    #expect(!belongs(bundle: "com.google.Chrome.canary", owner: "com.google.Chrome.canary", to: "com.google.Chrome"))
    #expect(!belongs(bundle: "com.apple.WebKit.GPU", owner: "com.apple.mail", to: "com.apple.Safari"))
    #expect(belongs(bundle: "com.apple.avconferenced", owner: nil, to: "com.apple.FaceTime"))  // its calls
    #expect(!belongs(bundle: "com.apple.avconferenced", owner: nil, to: "com.apple.Music"))
}

@Test func knownAudioAppsAreListedOnce() {
    #expect(Set(knownAudioApps).count == knownAudioApps.count)
}

// Silent at the bottom, the app's own level at the top, and quieter than linear in between.
@Test func appGainCurve() {
    #expect(appGain(0) == 0 && appGain(1) == 1 && appGain(0.5) == 0.125)
}
#endif

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

#if canImport(AppKit)
@Test func profilesAndShortcutsSurviveSaving() throws {
    let games = [Profile(name: "Games", jobs: jobs, shortcut: Shortcut(
        keyCode: 18, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "1"))]
    #expect(try JSONDecoder().decode([Profile].self, from: JSONEncoder().encode(games)) == games)
    #expect(games[0].shortcut?.label == "⌃⌥1")
    let f1 = Shortcut(keyCode: 122, modifiers: NSEvent.ModifierFlags.command.rawValue, key: "\u{F704}")
    #expect(f1.label == "⌘F1")
}
#endif
