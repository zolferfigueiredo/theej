import Foundation
import Testing
@testable import TheeJ

@Test func lightFramesLightOnlyTheStripButtons() {
    for pattern in lightPatterns {
        for step in 0..<40 {
            let frame = lightFrame(pattern, Double(step) * 0.07)
            #expect(Set(frame).count == frame.count && Set(frame).isSubset(of: smcStripButtons), "\(pattern) at step \(step)")
        }
    }
    #expect(lightFrame("on", 3).count == 32)
    #expect(lightFrame("", 1).isEmpty && lightFrame("off", 1).isEmpty)
}

@Test func chaseAndBounceLightOneColumn() {
    func column(_ frame: [Int]) -> Int? { frame.count == 4 ? (frame[0] - 128) % 8 : nil }
    #expect(column(lightFrame("chase", 0.01)) == 0 && column(lightFrame("chase", 0.13)) == 1)
    #expect(column(lightFrame("chase", 0.12 * 8 + 0.01)) == 0)
    #expect(column(lightFrame("bounce", 0.09 * 7 + 0.01)) == 7 && column(lightFrame("bounce", 0.09 * 8 + 0.01)) == 6)
}

@Test func lightPatternsByName() {
    for (name, want) in ["wave": "wave", "off": "", "": "", "disco": ""] { #expect(parseLightPattern(name) == want) }
    #expect(nextLightPattern("on") == "random" && nextLightPattern("wave") == "sparkle" && nextLightPattern("clock") == "")
    #expect(previousLightPattern("") == "clock" && previousLightPattern("on") == "" && previousLightPattern("random") == "on")
    #expect(!animated("on") && !animated("") && animated("sparkle"))
    #expect(isEQ("eqgame") && !isEQ("fire") && EQ("eq2") != nil && EQ("wave") == nil)
}

@Test func randomChangesPatternEverySixSeconds() {
    var last = ""
    for n in 0..<50 {
        let pattern = randomPattern(Double(n) * 6 + 1)
        #expect(pattern != last && animated(pattern) && !isEQ(pattern) && pattern != "clock" && pattern != "random")
        #expect(randomPattern(Double(n) * 6 + 5.9) == pattern)
        last = pattern
    }
}

@Test func eqFrameFillsEachColumnToItsBand() {
    let frame = eqFrame([0, 1, 0.5, 0, 0, 0, 0, 0.05])
    #expect(Set(frame) == Set([noteButton(16 + 1), noteButton(8 + 1), noteButton(0 + 1), noteButton(0 + 2),
                               noteButton(24 + 1), noteButton(24 + 2)]))
}

// 12:34:56: the hours' 1 lights the bottom of column 1, the 2 the row above in column 2, and so on.
@Test func clockFrameShowsTheTimeInBinary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12, minute: 34, second: 56)))
    let frame = Set(clockFrame(date, calendar: calendar))
    func lit(_ row: Int, _ column: Int) -> Bool { frame.contains(noteButton([16, 8, 0, 24][row] + column)) }
    #expect(lit(3, 1) && !lit(2, 1) && lit(2, 2) && !lit(3, 2) && lit(2, 6) && lit(1, 6) && !lit(3, 6))
}

private func tone(_ hz: Double, _ amplitude: Double) -> [Float32] {
    (0..<1920).map { Float32(amplitude * sin(2 * Double.pi * hz * Double($0) / 48000)) }
}

@Test func spectrumJumpsTheBandThatGetsLouder() {
    let sound = Spectrum()
    let eq = EQ("eq")!
    var now = 0.0
    // Two quiet tones for a while, a bass and a high one, then the high one jumps.
    for _ in 0..<100 {
        sound.add(left: tone(60, 0.05), right: tone(60, 0.05))
        sound.add(left: tone(3000, 0.02), right: tone(3000, 0.02))
        now += 0.04
        _ = eq.columns(sound, now: now)
    }
    let loud = zip(tone(3000, 0.5), tone(60, 0.05)).map { $0 + $1 }
    sound.add(left: loud, right: loud)
    sound.add(left: loud, right: loud)
    now += 0.04
    let bands = eq.columns(sound, now: now)
    #expect(bands[5] >= 0.9 && bands[0] <= 0.6, "\(bands)")
    let silence = [Float32](repeating: 0, count: fftSize)
    sound.add(left: silence, right: silence)
    #expect(eq.columns(sound, now: now + 2) == Array(repeating: 0, count: 8))
}

@Test func eqGamingShowsEachSideOnItsOwnHalf() {
    let sound = Spectrum()
    let eq = EQ("eqgame")!
    var now = 0.0
    for _ in 0..<100 {
        sound.add(left: tone(200, 0.01), right: tone(12000, 0.01))
        now += 0.04
        _ = eq.columns(sound, now: now)
    }
    // A loud bass on the left only, and quiet highs on the right.
    sound.add(left: tone(200, 0.5), right: tone(12000, 0.01))
    sound.add(left: tone(200, 0.5), right: tone(12000, 0.01))
    now += 0.04
    let columns = eq.columns(sound, now: now)
    #expect(columns[0] >= 0.9 && columns[7] <= 0.6, "\(columns)")
}

@Test func interleavedSoundFillsBothSides() {
    let sound = Spectrum()
    let eq = EQ("eqgame")!
    let frames = zip(tone(200, 0.5), tone(200, 0)).flatMap { [$0, $1] }  // loud left, silent right
    frames.withUnsafeBufferPointer { sound.add(interleaved: $0, channels: 2) }
    frames.withUnsafeBufferPointer { sound.add(interleaved: $0, channels: 2) }
    let columns = eq.columns(sound, now: 0.04)
    #expect(columns[0] > 0 && columns[7] == 0, "\(columns)")
}

@Test func mixerStateSaysWhichColumnMoved() {
    var mixer = MixerState()
    _ = mixer.feed(0xE2 | 5 << 8 | 70 << 16)
    #expect(mixer.lastChanged == 42)
    _ = mixer.feed(0x90 | 16 << 8 | 127 << 16)
    #expect(mixer.lastChanged == nil)
    _ = mixer.feed(0xB0 | 16 << 8 | 1 << 16)
    #expect(mixer.lastChanged == 30)
}

@Test func onlyAnSMCMixerKeepsALightPattern() throws {
    let saved = #"[{"id":"d1","name":"SMC","type":"smc","lights":"wave"},{"id":"d2","name":"Desk","type":"diy","lights":"wave"},"#
        + #"{"id":"d3","name":"Twin","type":"smc","lights":"disco"}]"#
    let boards = try JSONDecoder().decode([Board].self, from: Data(saved.utf8))
    #expect(boards.map(\.lights) == ["wave", "", ""])
    let encoded = try JSONEncoder().encode(boards)
    #expect(try JSONDecoder().decode([Board].self, from: encoded).map(\.lights) == ["wave", "", ""])
}
