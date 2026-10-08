import Testing
@testable import TheeJ

private func note(_ number: Int, _ velocity: Int) -> UInt32 { 0x90 | UInt32(number) << 8 | UInt32(velocity) << 16 }
private func cc(_ control: Int, _ value: Int) -> UInt32 { 0xB0 | UInt32(control) << 8 | UInt32(value) << 16 }
private func fader(_ value: Int) -> UInt32 { 0xE0 | UInt32(value) << 16 }

@Test func smcButtonsAreTheSameInBothModes() {
    var mixer = MixerState()
    func press(_ message: UInt32) -> Int? { mixer.feed(message).pressed }
    for i in 0..<8 {
        #expect(press(cc(20 + i, 127)) == noteButton(16 + i) && press(note(16 + i, 127)) == noteButton(16 + i))
        #expect(press(cc(smcSCCs[i], 127)) == press(note(8 + i, 127)))
    }
    for (i, n) in smcBottomNotes.enumerated() { #expect(press(cc(52 + i, 127)) == press(note(n, 127))) }
    #expect(press(cc(50, 127)) == noteButton(14))
}

@Test func smcButtonCCsRoundTrip() {
    let withCC = smcButtonOrder.compactMap { id in smcCC(button: id).map { (id, $0) } }
    #expect(withCC.allSatisfy { smcButton(cc: $0.1) == $0.0 })
    #expect(withCC.count == 27 && smcCC(button: noteButton(0)) == nil)  // M, S and the bottom row; R has none
}

@Test func smcNamesAndControls() {
    for name in ["SINCO SMC-Mixer-Master", "SINCO SMC-Mixer-Private", "SMC-Mixer", "MIDIIN2 (SMC-Mixer)"] { #expect(isSMCName(name)) }
    #expect(!isSMCName("nanoKONTROL2"))
    #expect(Board.smcControls.map(\.input) == smcColumns)
}

@Test func smcModeFollowsTheMixer() {
    let steps: [(UInt32, Bool?)] = [(0xE3 | 64 << 16, true), (cc(40, 64), false), (note(16, 127), true), (cc(20, 127), false),
                                    (cc(20, 65), true), (cc(52, 0), false), (0x80 | 16 << 8, true), (0xF8, nil)]
    for (message, daw) in steps { #expect(smcMode(message) == daw, "\(message)") }
}

@Test func smcLights() {
    #expect(smcLight(noteButton(16), on: true, daw: true) == note(16, 127))
    #expect(smcLight(noteButton(16), on: false, daw: false) == cc(20, 0))
    #expect(smcLight(noteButton(24), on: true, daw: false) == nil)  // Square sends nothing in CC mode
    #expect(smcStripButtons.count == 32 && !smcStripButtons.contains(noteButton(94)))
}

@Test func smcButtonsReleaseInBothModes() {
    #expect(smcReleased(note(16, 0)) == noteButton(16))
    #expect(smcReleased(0x80 | 94 << 8 | 64 << 16) == noteButton(94))
    #expect(smcReleased(note(16, 127)) == nil)
    #expect(smcReleased(cc(20, 0)) == noteButton(16))
    #expect(smcReleased(cc(20, 127)) == nil && smcReleased(cc(40, 0)) == nil)
}

@Test func mixerValuesScaleToColumns() {
    var mixer = MixerState()
    #expect(mixer.values.allSatisfy { $0 == -1 })
    for (message, column, value) in [(cc(40, 0), 40, 0), (cc(40, 127), 40, 1023), (cc(47, 64), 47, 516), (cc(30, 127), 30, 1023),
                                     (cc(37, 1), 37, 8), (cc(9, 100), 9, 806)] {
        let (changed, pressed) = mixer.feed(message)
        #expect(changed && pressed == nil && mixer.values[column] == value)
    }
    #expect(!mixer.feed(cc(37, 1)).changed)
    #expect(mixer.values[41] == -1)
}

@Test func mixerButtonsPressOnlyOnTheWayDown() {
    var mixer = MixerState()
    let press = mixer.feed(cc(20, 127))
    #expect(!press.changed && press.pressed == noteButton(16))
    #expect(mixer.feed(cc(20, 0)).pressed == nil)
    #expect(mixer.feed(0x90 | 40 << 8 | 100 << 16).pressed == noteButton(40))
    #expect(mixer.feed(note(24, 0)).pressed == nil)
}

@Test func everyMixerButtonIsListedOnce() {
    #expect(Set(smcButtonOrder).count == 43 && smcButtonOrder.count == 43)
    #expect((0..<128).filter { smcButton(cc: $0) != nil && smcColumns.contains($0) }.isEmpty)
    #expect(smcDefaultButtons.keys.allSatisfy(smcButtonOrder.contains) && smcDefaultButtons.values.joined().allSatisfy(validAction))
}

@Test func moveWatcherIgnoresJitter() {
    var watcher = MoveWatcher()
    #expect(watcher.moved([500, -1]).isEmpty)
    #expect(watcher.moved([505, -1]).isEmpty)
    #expect(watcher.moved([520, 300]) == [0, 1])  // a real turn, and a mixer control's first report
    #expect(watcher.moved([528, 300]).isEmpty)
}

@Test func dawModeLandsOnTheSameColumns() {
    var mixer = MixerState()
    _ = mixer.feed(0xE0 | 127 << 16)
    _ = mixer.feed(0xE7 | 64 << 16)
    #expect(mixer.values[40] == 1023 && mixer.values[47] == 516)
    _ = mixer.feed(cc(16, 1))
    _ = mixer.feed(cc(16, 1))
    _ = mixer.feed(cc(16, 65))
    #expect(mixer.values[30] == 512 + 4)  // two steps up and one down from the middle
    for _ in 0..<300 { _ = mixer.feed(cc(17, 65)) }
    #expect(mixer.values[31] == 0)
    #expect(mixer.feed(cc(20, 127)).pressed == noteButton(16))
    #expect(mixer.feed(cc(20, 1)).pressed == nil && mixer.values[34] == 516)  // knob 5 stepping, not M1
}

// A knob that hasn't moved starts where its job is, not in the middle, so its first turn doesn't jump.
@Test func knobsStartWhereTheirJobIs() {
    var mixer = MixerState()
    _ = mixer.feed(cc(16, 2)) { $0 == 30 ? 800 : nil }
    #expect(mixer.values[30] == 808)
    _ = mixer.feed(cc(17, 65)) { _ in nil }
    #expect(mixer.values[31] == 508)
    mixer.forgetKnobs()
    #expect(mixer.values[30] == -1 && mixer.values[31] == -1)
}

@Test func diyButtonsPressEitherWay() {
    var watcher = ButtonWatcher()
    let inputs = [4: 0, 5: 1]
    func press(_ a: Int, _ b: Int, _ now: Double) -> [Int] { watcher.pressed([a, b], inputs, at: now) }
    #expect(press(0, 1023, 0).isEmpty)  // the first frame is where they rest
    #expect(press(1023, 1023, 1) == [4])
    #expect(press(0, 1023, 1.01).isEmpty)
    #expect(press(1023, 1023, 1.02).isEmpty)  // a bounce right after
    _ = press(0, 1023, 1.03)
    #expect(press(1023, 0, 2) == [4, 5])
    #expect(press(1023 - 150, 150, 2.1).isEmpty)  // still held
}

// Lit lights pull a resting fader's reading for seconds; a hand moves it further than that.
@Test func lightGuardHoldsTheDriftLightsCause() {
    var guardian = LightGuard()
    func pass(_ message: UInt32, _ now: Double, _ lightChanged: Double) -> Bool {
        guardian.pass(message, now: now, lightChanged: lightChanged)
    }
    #expect(pass(fader(127), 0, -10))
    #expect(!pass(fader(124), 1, 0.5))
    #expect(!pass(fader(123), 4.8, 0.5))  // 4.3 s after, as measured
    #expect(pass(fader(110), 5, 0.5))
    #expect(pass(fader(109), 5.1, 0.5))  // followed closely while it moves
    #expect(pass(fader(105), 9, 0.5))
    #expect(pass(note(16, 127), 9, 9))
}

@Test func universalPacketsBecomeShortMessages() {
    #expect(shortMessages([0x20E3_0040, 0x2090_107F]) == [0xE3 | 0x40 << 16, note(16, 127)])
    // A two-word sysex between them is stepped over without losing step.
    #expect(shortMessages([0x2090_107F, 0x3016_F07E, 0x7F06_0100, 0x20B0_1001]) == [note(16, 127), cc(16, 1)])
    #expect(universalPacket(note(16, 127)) == 0x2090_107F && universalPacket(cc(20, 0)) == 0x20B0_1400)
}

@Test func buttonActionsValidate() {
    for action in ["media.playpause", "media.stop", "profile.next", "settings", "mute:0", "mute:15", "open:com.spotify.client",
                   "close:com.spotify.client", "url:https://theej.zolfer.com", "url:HTTP://example.com", "keys:1048576:46:m",
                   "keys:0:41::", "profile:2", "nightlight", "pc.lock", "lights.next"] {
        #expect(validAction(action), "\(action)")
    }
    for action in ["bogus", "mute:", "mute:-1", "mute:x", "mute:01", "open:", "url:file:///etc", "url:", "keys:", "keys:x:1:a",
                   "profile:-1", "pc.reboot"] {
        #expect(!validAction(action), "\(action)")
    }
    let colon = Shortcut(keyCode: 41, modifiers: 131072, key: ":")
    #expect(pressedKeys(keysAction(colon)) == colon)
    #expect(mutedControl("mute:3") == 3 && profileTarget("profile:3") == 3 && profileTarget("mute:1") == nil)
    #expect(functionKeys.count == 8 && functionKeys.allSatisfy { validAction($0.action) && actionKind($0.action) == $0.action })
    #expect(actionKind("url:https://x.y") == "url:" && actionKind("keys:0:4:h") == "keys:" && actionKind("pc.sleep") == "pc.sleep")
}
