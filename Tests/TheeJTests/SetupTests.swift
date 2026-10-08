import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import TheeJ

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

// The rank bands must stay distinct as target kinds are added.
private let every: [Target] = [.master, .microphone, .builtinBrightness, .builtinContrast, .nightShift]
    + (0..<16).flatMap { [.brightness($0), .contrast($0)] } + [.builtinKeyboard, .externalKeyboard, .zoom, .app("com.apple.Music")]

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

// Knobs saved before profiles still load, to become the first board.
@Test func knobsSavedBeforeProfilesStillLoad() throws {
    let saved = #"[{"target":{"master":{}},"column":0},{"target":{"brightness":{"_0":0}},"column":3},"#
        + #"{"target":{"brightness":{"_0":1}},"column":2},{"column":4},{"target":{"builtinBrightness":{}},"column":1}]"#
    #expect(try JSONDecoder().decode([Knob].self, from: Data(saved.utf8)) == [
        Knob(column: 0, target: .master), Knob(column: 3, target: .brightness(0)), Knob(column: 2, target: .brightness(1)),
        Knob(column: 4, target: nil), Knob(column: 1, target: .builtinBrightness),
    ])
}

// Profiles from before boards, as 1.8 and earlier saved them so that older versions could read them: one
// job per knob in "targets", an app's in "apps", every job in "jobs" once a knob had several, and zoom in
// "zoom". They still load, to become the first board's.
@Test func profilesSavedBeforeBoardsStillLoad() throws {
    _ = english
    let saved = #"[{"name":"Default","targets":[{"master":{}},null]},"#
        + #"{"name":"Music","targets":[{"master":{}},null,null],"apps":[null,"com.spotify.client",null]},"#
        + #"{"name":"Desk","targets":[{"master":{}},null,null],"apps":[null,"com.google.Chrome",null],"#
        + #""jobs":[[{"master":{}},{"app":{"_0":"com.apple.Music"}}],[{"app":{"_0":"com.google.Chrome"}},{"master":{}}],[]]},"#
        + #"{"name":"Reading","targets":[{"master":{}},null,null],"jobs":[[{"master":{}},{"microphone":{}}],[],[]],"zoom":[0,1]}]"#
    #expect(try JSONDecoder().decode([Profile].self, from: Data(saved.utf8)) == [
        Profile(name: "Default", jobs: [[.master], []]),
        Profile(name: "Music", jobs: [[.master], [.app("com.spotify.client")], []]),
        Profile(name: "Desk", jobs: [[.master, .app("com.apple.Music")], [.app("com.google.Chrome"), .master], []]),
        Profile(name: "Reading", jobs: [[.master, .microphone, .zoom], [.zoom], []]),
    ])
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
    var board = Board.make(id: "d1", name: "Desk", type: .diy, knobs: 1, profileName: "A")
    board.profiles += [board.newProfile("B"), board.newProfile("C")]
    #expect(board.stepped(1) == 1 && board.stepped(-1) == 2)
    board.active = 2
    #expect(board.stepped(1) == 0 && board.stepped(-1) == 1)
}

#if canImport(AppKit)
@Test func profilesAndShortcutsSurviveSaving() throws {
    let games = [Profile(name: "Games", jobs: [[.master], [.brightness(1)], []], shortcut: Shortcut(
        keyCode: 18, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "1"), buttons: [144: ["mute:0"]])]
    #expect(try JSONDecoder().decode([Profile].self, from: JSONEncoder().encode(games)) == games)
    #expect(games[0].shortcut?.label == "⌃⌥1")
    let f1 = Shortcut(keyCode: 122, modifiers: NSEvent.ModifierFlags.command.rawValue, key: "\u{F704}")
    #expect(f1.label == "⌘F1")
    #expect(pressedKeys(functionKeys[0].action)?.label == "F13")
}
#endif

// Past Z the letters start again with a number: there is no last knob.
@Test func knobLettersNeverRunOut() {
    #expect([0, 25, 26, 51, 52].map(letter) == ["A", "Z", "A2", "Z2", "A3"])
}

// A control past the end of a profile's jobs has none, so padding the jobs leaves Apply off.
@Test func emptyJobsAtTheEndChangeNothing() {
    #expect(Profile(name: "a", jobs: [[.master], []]) == Profile(name: "a", jobs: [[.master]]))
    #expect(Profile(name: "a", jobs: [[], [.master]]) != Profile(name: "a", jobs: [[.master]]))
    #expect(Profile(name: "a", buttons: [144: ["mute:0"]]) != Profile(name: "a"))
}
