import Foundation
import Testing
@testable import TheeJ

// The strings expected below are English, whatever language this Mac uses.
private let english: Void = UserDefaults.standard.set("en", forKey: "language")

// A defaults domain of its own, empty, so a test never reads or writes this Mac's TheeJ settings.
private func defaults(_ name: String) -> UserDefaults {
    let suite = "com.zolfer.theej.tests.\(name)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test func newBoardsHaveTheirControls() {
    let desk = Board.make(id: "d1", name: "Desk", type: .diy, knobs: 2, faders: 1, buttons: 2, profileName: "Default")
    #expect(desk.controls.map(\.kind) == [.knob, .knob, .fader, .button, .button])
    #expect(desk.controls.allSatisfy { $0.input == nil && $0.min == 0 && $0.max == 1023 && !$0.reverse })
    #expect(desk.profiles.map(\.name) == ["Default"] && desk.profiles[0].jobs.count == 5 && !desk.calibrated)
    #expect(desk.buttonKeys == [3, 4])  // a DIY board's buttons go by control index

    let smc = Board.make(id: "d2", name: "SMC", type: .smc, knobs: 9, profileName: "Default")
    #expect(smc.controls.count == 16 && smc.calibrated && smc.controls[0].input == 40 && smc.controls[8].kind == .knob)
    #expect(smc.profiles[0].buttons[noteButton(16)] == ["mute:0"] && smc.profiles[0].buttons[noteButton(47)] == ["profile.next"])
    #expect(smc.buttonKeys == smcButtonOrder && smc.isButton(noteButton(0)) && !smc.isButton(15))

    // Another MIDI board's buttons go by the id they send, so they have no key until they are found.
    var pads = Board.make(id: "d3", name: "Pads", type: .midi, knobs: 1, buttons: 1, profileName: "Default")
    #expect(pads.buttonKeys.isEmpty)
    pads.controls[1].input = 36
    #expect(pads.buttonKeys == [36] && pads.control(ofKey: 36) == 1)
}

@Test func controlsAreNamedAsThePanelNamesThem() {
    _ = english
    let smc = Board.make(id: "d1", name: "SMC", type: .smc, profileName: "Default")
    #expect([0, 8, noteButton(16), noteButton(8), noteButton(0), noteButton(24), noteButton(94), noteButton(47)].map(smc.controlName)
        == ["Fader 1", "Knob 1", "M1", "S1", "R1", "Square 1", "Play", "Next bank"])
    let desk = Board.make(id: "d2", name: "Desk", type: .diy, knobs: 1, faders: 1, buttons: 1, profileName: "Default")
    #expect((0..<3).map(desk.controlName) == ["Knob A", "Fader B", "Button C"])
}

@Test func normalizeScalesEachControlToItsTravel() {
    var board = Board(id: "d1", name: "Desk", type: .diy)
    board.controls = [Control(kind: .knob, input: 2, min: 100, max: 900), Control(kind: .fader, input: 0, reverse: true),
                      Control(kind: .button, input: 1), Control(kind: .knob), Control(kind: .knob, input: 3)]
    let values = board.normalize([200, 1023, 500, -1])
    #expect(values[0] == 511 && values[2] == -1 && values[3] == -1 && values[4] == -1)
    #expect(values[1] == 1023 - (200 - 20) * 1023 / (1003 - 20))
    let ends = board.normalize([1015, 0, 110, 0])
    #expect(ends[0] == 0 && ends[1] == 0)
    // A knob started where its job is reads back there, within a step.
    for value in [0, 300, 512, 1023] {
        #expect(abs(board.normalize([board.raw(value, of: 1), 0, 0, 0])[1] - value) <= 2)
        #expect(abs(board.normalize([0, 0, board.raw(value, of: 0), 0])[0] - value) <= 2)
    }
}

@Test func boardsSurviveSavingByteForByte() throws {
    var desk = Board.make(id: "d1", name: "Desk", type: .diy, knobs: 2, buttons: 1, profileName: "Default")
    desk.controls[0] = Control(kind: .knob, input: 3, reverse: true)
    desk.controls[1] = Control(kind: .knob, input: 1, min: 12, max: 1000)
    desk.profiles[0].jobs = [[.master, .app("com.apple.Music")], [.zoom], []]
    desk.profiles[0].buttons = [2: ["media.playpause", "url:https://theej.zolfer.com"]]
    desk.next = Shortcut(keyCode: 124, modifiers: 1 << 20, key: "\u{F703}")
    (desk.port, desk.baud, desk.speed, desk.list) = ("/dev/cu.usbserial-10", 115200, .fast, true)
    var smc = Board.make(id: "d2", name: "SMC", type: .smc, profileName: "Default")
    smc.enabled = false
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let once = try encoder.encode([desk, smc])
    let back = try JSONDecoder().decode([Board].self, from: once)
    #expect(back == [desk, smc])
    #expect(try encoder.encode(back) == once)
}

// One bad value is dropped on its own, never the board or the profile it is in. Only a board of a type
// this version doesn't know goes.
@Test func aBadValueDropsOnlyItself() throws {
    _ = english
    let saved = #"[{"id":"d1","name":"Desk","type":"diy","controls":[{"kind":"slider","input":0,"min":-5,"max":2000}],"#
        + #""profiles":[{"name":"A","jobs":[[{"master":{}},{"systemSounds":{}}]],"#
        + #""buttons":{"7":["media.next","pc.reboot","media.next"],"x":["media.next"],"300":["settings"],"8":"settings"}}],"#
        + #""profile":4,"speed":"warp","baudRate":-1},{"id":"d2","type":"stage-lights"},{"id":"d3","name":"Twin","type":"smc"}]"#
    let boards = try JSONDecoder().decode([Lossy<Board>].self, from: Data(saved.utf8)).compactMap(\.value)
    #expect(boards.map(\.name) == ["Desk", "Twin"])
    #expect(boards[0].controls == [Control(kind: .knob, input: 0)])
    #expect(boards[0].profiles[0].jobs == [[.master]])
    #expect(boards[0].profiles[0].buttons == [7: ["media.next"], 8: ["settings"]])
    #expect(boards[0].active == 0 && boards[0].speed == .slow && boards[0].baud == 9600)
    #expect(boards[1].controls == Board.smcControls && boards[1].profiles.map(\.name) == ["Default"])
}

// What TheeJ 1.8 saved becomes board d1, and stays where it was for a downgrade.
@Test func theBoardFromBeforeBoardsBecomesD1() throws {
    _ = english
    let old = defaults("migration")
    old.set(#"[0,3,null]"#, forKey: "columns")
    old.set(#"[{"name":"Music","targets":[{"master":{}},null]},"#
        + #"{"name":"Calls","targets":[null,{"microphone":{}}],"shortcut":{"keyCode":18,"modifiers":262144,"key":"1"}}]"#,
            forKey: "profiles")
    old.set(1, forKey: "profile")
    old.set(true, forKey: "invertKnobs")
    old.set("fast", forKey: "speed")
    old.set(#"{"keyCode":124,"modifiers":1048576,"key":""}"#, forKey: "nextProfile")
    let setup = Setup.load(from: old)
    #expect(setup.boards.count == 1 && setup.added == 1)
    let board = setup.boards[0]
    #expect(board.id == "d1" && board.name == "DIY (Arduino)" && board.type == .diy && board.list)
    #expect(board.speed == .fast && board.active == 1 && board.port.isEmpty && board.baud == 9600)
    // Invert was on, which undid 1.8's 1 - raw, so the knobs read straight.
    #expect(board.controls == [Control(kind: .knob, input: 0), Control(kind: .knob, input: 3), Control(kind: .knob)])
    #expect(board.profiles.map(\.jobs) == [[[.master], [], []], [[], [.microphone], []]])
    #expect(board.profiles[1].shortcut?.keyCode == 18 && board.next?.keyCode == 124)
    #expect(old.string(forKey: "boards") != nil && old.string(forKey: "columns") == #"[0,3,null]"#)
    #expect(Setup.load(from: old) == setup)

    // Knobs from before profiles, with Invert off: read as 1 - raw, so each is reversed.
    let older = defaults("knobs")
    older.set(#"[{"target":{"master":{}},"column":1},{"column":0}]"#, forKey: "knobs")
    let first = try #require(Setup.load(from: older).boards.first)
    #expect(first.controls == [Control(kind: .knob, input: 1, reverse: true), Control(kind: .knob, input: 0, reverse: true)])
    #expect(first.profiles.map(\.jobs) == [[[.master], []]])
}

@Test func aFreshInstallHasNoBoards() {
    let fresh = defaults("fresh")
    #expect(Setup.load(from: fresh).boards.isEmpty && fresh.string(forKey: "boards") == nil)
}

@Test func onceThereAreBoardsTheOldKeysAreLeftAlone() {
    let both = defaults("both")
    let old = #"[{"name":"Old","targets":[{"master":{}}]}]"#
    both.set(#"[5]"#, forKey: "columns")
    both.set(old, forKey: "profiles")
    var setup = Setup()
    setup.boards = [Board.make(id: "d4", name: "SMC", type: .smc, profileName: "New"),
                    Board.make(id: "d4", name: "Twin", type: .smc, profileName: "New")]
    setup.save(to: both)
    let loaded = Setup.load(from: both)
    // A second board on the same id gets the next one, and ids past it are never given out again.
    #expect(loaded.boards.map(\.name) == ["SMC", "Twin"] && loaded.boards.map(\.id) == ["d4", "d5"] && loaded.added == 5)
    #expect(both.string(forKey: "profiles") == old)
}

@Test func oneKeyCombinationSwitchesEveryBoardUsingIt() {
    let f1 = Shortcut(keyCode: 122, modifiers: 1 << 20, key: "\u{F704}")
    var desk = Board.make(id: "d1", name: "Desk", type: .diy, knobs: 1, profileName: "One")
    desk.profiles.append(desk.newProfile("Two"))
    desk.profiles[1].shortcut = f1
    desk.next = Shortcut(keyCode: 120, modifiers: 1 << 20, key: "\u{F705}")
    var smc = Board.make(id: "d2", name: "SMC", type: .smc, profileName: "One")
    smc.profiles[0].shortcut = Shortcut(keyCode: 122, modifiers: 1 << 20, key: "x")  // the same keys on another layout
    var spare = Board.make(id: "d3", name: "Spare", type: .diy, knobs: 1, profileName: "One")
    (spare.enabled, spare.next) = (false, f1)
    #expect(hotKeyBindings([desk, smc, spare]) == [
        HotKeyBinding(shortcut: desk.next!, targets: [HotKeyTarget(board: "d1", step: 1)]),
        HotKeyBinding(shortcut: f1, targets: [HotKeyTarget(board: "d1", profile: 1), HotKeyTarget(board: "d2", profile: 0)]),
    ])
    #expect(alsoUsedBy(f1, besides: "d1", in: [desk, smc, spare]) == ["SMC"])
}
