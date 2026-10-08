import Foundation
import Testing
@testable import TheeJ

// The strings expected below are English, whatever language this Mac uses.
private let english: Void = UserDefaults.standard.set("en", forKey: "language")

// weej's deejimport_test.go fixture.
private let deejFixture = """
slider_mapping:
  0: master
  3: monitor 1 (brightness)
  2: monitor 2 (brightness)
  4:
    - cs2.exe
    - rocketleague.exe
    - RocketLeague.exe
    - roblox.exe
    - steam.exe
    - steamwebhelper.exe
    - steamservice.exe
    - vlc.exe
    - deej.unmapped
  1:
    - chrome.exe
    - brave.exe
    - firefox.exe
    - opera.exe
    - edge.exe
    - msedge.exe
    - spotify.exe
  6: FxSound.exe
invert_sliders: true
com_port: COM6
baud_rate: 9600
noise_reduction: default
"""

@Test func deejSlidersGoToTheKnobOnTheirInput() throws {
    var desk = Board.make(id: "d1", name: "Desk", type: .diy, knobs: 7, profileName: "Default")
    for index in desk.controls.indices { desk.controls[index].input = 6 - index }  // wired right to left
    let (profile, skipped) = try #require(importedProfile(Data(deejFixture.utf8), for: desk))
    #expect(profile.name == "deej" && profile.jobs.count == 7)
    #expect(profile.jobs[6] == [.master] && profile.jobs[3] == [.brightness(0)] && profile.jobs[4] == [.brightness(1)])
    #expect(profile.jobs.joined().count == 3)
    #expect(skipped == ["cs2.exe", "rocketleague.exe", "roblox.exe", "steam.exe", "steamwebhelper.exe", "steamservice.exe",
                        "vlc.exe", "deej.unmapped", "chrome.exe", "brave.exe", "firefox.exe", "opera.exe", "edge.exe",
                        "msedge.exe", "spotify.exe", "FxSound.exe"])
}

@Test func deejSlidersGoByPlaceOnAMixer() throws {
    let yaml = "\u{FEFF}# my mixer\r\nslider_mapping:\r\n  0:\r\n    - master   # main\r\n    - Headset Microphone (Realtek)\r\n"
        + "  \"1\": [mic, 'monitor 2 (brightness)', Mic]\r\n  20: master\r\n  x: master\r\ninvert_sliders: false\r\n"
    let smc = Board.make(id: "d1", name: "SMC", type: .smc, profileName: "Default")
    let (profile, skipped) = try #require(importedProfile(Data(yaml.utf8), for: smc))
    #expect(profile.jobs[0] == [.master] && profile.jobs[1] == [.microphone, .brightness(1)] && profile.jobs.joined().count == 3)
    #expect(skipped == ["Headset Microphone (Realtek)", "slider 20", "x"])
    #expect(profile.buttons == smcDefaultButtons)
}

@Test func otherFilesAreNotProfiles() {
    let smc = Board.make(id: "d1", name: "SMC", type: .smc, profileName: "Default")
    for text in ["", "hello", #"{"kind":"weej.settings","profile":{"name":"A","jobs":[]}}"#, "invert_sliders: true\n"] {
        #expect(importedProfile(Data(text.utf8), for: smc) == nil, "\(text)")
    }
}

@Test func anExportedProfileComesBackTheSame() throws {
    var desk = Board.make(id: "d1", name: "Desk", type: .diy, knobs: 3, buttons: 1, profileName: "Music")
    desk.profile.jobs = [[.master, .app("com.spotify.client")], [.builtinContrast, .brightness(1)], [.builtinKeyboard], []]
    desk.profile.buttons = [3: ["media.playpause", keysAction(Shortcut(keyCode: 0, modifiers: 1 << 20, key: "a")), "open:com.apple.Safari"]]
    desk.profile.shortcut = Shortcut(keyCode: 18, modifiers: 1 << 20, key: "1")
    let data = try #require(profileFile(desk.profile, of: desk))
    let (profile, skipped) = try #require(importedProfile(data, for: desk))
    #expect(skipped.isEmpty && profile.name == "Music" && profile.shortcut == nil)
    #expect(profile.jobs == desk.profile.jobs && profile.buttons == desk.profile.buttons)

    // WeeJ reads only jobs it knows, and would refuse the whole file over one it doesn't.
    let file = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(file["kind"] as? String == "weej.profile" && file["version"] as? Int == 1 && file["type"] as? String == "diy")
    #expect(file["platform"] as? String == "macos")
    let saved = try #require(file["profile"] as? [String: Any])
    let jobs = try #require(saved["jobs"] as? [[[String: Any]]])
    #expect(jobs.map { $0.map { $0["kind"] as? String } } == [["master"], ["brightness"], [], []] && jobs[1][0]["screen"] as? Int == 1)
    #expect(saved["shortcut"] == nil && (saved["buttons"] as? [String: [String]])?["3"]?.count == 3)
}

@Test func aWindowsProfileLeavesItsAppsAndKeysBehind() throws {
    _ = english
    let weej = #"""
        {"kind":"weej.profile","version":1,"type":"smc","profile":{"name":"Games","jobs":[
          [{"kind":"master"},{"kind":"systemSounds"},{"kind":"master"}],
          [{"kind":"app","exe":"spotify.exe"},{"kind":"nightLight"}],
          [{"kind":"brightness","screen":0}],
          [{"kind":"brightness","screen":99}, 7]],
        "buttons":{"144":["mute:0","open:C:\\Apps\\Steam.exe"],"174":["keys:2:65:A","media.playpause","disco"]}}}
        """#
    let smc = Board.make(id: "d1", name: "SMC", type: .smc, profileName: "Default")
    let (profile, skipped) = try #require(importedProfile(Data(weej.utf8), for: smc))
    #expect(profile.name == "Games" && profile.jobs.count == 16)
    #expect(profile.jobs[0] == [.master] && profile.jobs[1] == [.nightShift] && profile.jobs[2] == [.brightness(0)] && profile.jobs[3].isEmpty)
    #expect(profile.buttons == [noteButton(16): ["mute:0"], noteButton(46): ["media.playpause"]])
    #expect(skipped == ["System sounds", "spotify.exe", "brightness", "M1: Open an app", "Previous bank: Press a shortcut"])

    // From another type of board only the jobs come, by control.
    let desk = Board.make(id: "d2", name: "Desk", type: .diy, knobs: 2, buttons: 1, profileName: "Default")
    let (deskProfile, _) = try #require(importedProfile(Data(weej.utf8), for: desk))
    #expect(deskProfile.jobs == [[.master], [.nightShift], [.brightness(0)]] && deskProfile.buttons.isEmpty)
}

@Test func controlsMoveBetweenRows() {
    var desk = Board.make(id: "d1", name: "Desk", type: .diy, knobs: 2, faders: 1, buttons: 2, profileName: "Default")
    #expect(desk.layout == nil && desk.rows == [[0, 1], [2], [3, 4]])
    #expect(!desk.canMove(0, .left) && !desk.canMove(2, .left) && !desk.canMove(2, .right) && desk.canMove(2, .up))
    desk.move(2, .up)  // a fader alone in its row joins the row above, at its place there
    #expect(desk.rows == [[2, 0, 1], [3, 4]])
    desk.move(0, .up)  // a control in the first row starts a new row above it
    #expect(desk.rows == [[0], [2, 1], [3, 4]] && !desk.canMove(0, .up))
    desk.move(4, .left)
    desk.move(4, .down)
    #expect(desk.rows == [[0], [2, 1], [3], [4]] && !desk.canMove(4, .down))

    // weej's TestBoardLayoutsStayDrawable: bad and repeated controls go, missing ones join the last row.
    desk.layout = [[2, 9, 0], [], [0, 4, -1]]
    #expect(desk.rows == [[2, 0], [4, 1, 3]])
    desk.layout = []
    #expect(desk.rows == [[0, 1, 2, 3, 4]])
}

@Test func onlyADrawnBoardKeepsItsLayout() throws {
    let saved = #"[{"id":"d1","name":"Desk","type":"diy","controls":[{"kind":"knob"},{"kind":"fader"}],"layout":[[1,0]]},"#
        + #"{"id":"d2","name":"SMC","type":"smc","layout":[[1,0]]},{"id":"d3","name":"Pads","type":"midi","layout":"x"}]"#
    let boards = try JSONDecoder().decode([Board].self, from: Data(saved.utf8))
    #expect(boards.map(\.layout) == [[[1, 0]], nil, nil] && boards[0].rows == [[1, 0]])
    let encoded = try JSONEncoder().encode(boards)
    #expect(try JSONDecoder().decode([Board].self, from: encoded).map(\.layout) == [[[1, 0]], nil, nil])
}
