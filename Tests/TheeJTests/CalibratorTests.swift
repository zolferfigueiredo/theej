import Testing
@testable import TheeJ

// Calibration finds the knob that swings, times only while it turns, then asks for the next knob until
// every input has one.
@Test func calibrationRun() {
    var run = Calibrator()
    var clock = 0.0
    func tick(_ values: [Int]) { clock += 0.03; run.feed(values, at: clock) }
    tick([500, 500, 500])
    tick([520, 500, 100])
    #expect(run.phase == 0 && !run.canSkip)  // column 2 has only swung 400, so knob A isn't found
    tick([520, 500, 1000])
    #expect(run.found == [2] && run.phase == 1 && run.canSkip && !run.paused)
    tick([520, 500, 1000])
    #expect(!run.paused)  // the turning doesn't open on "paused" before the knob has had a second
    for _ in 0..<1000 { tick([520, 500, 1000]) }  // 30 seconds untouched
    #expect(run.phase == 1 && run.left == Calibrator.turnSeconds && run.paused)
    tick([520, 500, 600])
    #expect(!run.paused)
    var turning = 400
    while run.phase == 1 { turning = 1000 - turning; tick([520, 500, turning]) }
    #expect(abs(clock - 30 - Calibrator.turnSeconds) < 1)
    #expect(run.knob == 1 && run.phase == 0)
    tick([520, 500, 0])
    tick([520, 500, 1023])
    #expect(run.phase == 0 && run.wrongKnob == 0)  // column 2 is knob A, so knob B cannot claim it
    tick([0, 500, 1023])
    #expect(run.found == [2, 0] && run.knob == 1 && run.phase == 1 && run.wrongKnob == nil)
    run.skip()
    #expect(run.knob == 2 && run.phase == 0 && !run.full)
    run.skip()
    #expect(run.knob == 2 && run.phase == 0)  // nothing to skip until knob C is found
    tick([0, 0, 1023])
    tick([0, 1023, 1023])
    #expect(run.found == [2, 0, 1])
    run.skip()
    tick([0, 1023, 1023])
    #expect(run.full && run.phase == 0 && !run.canSkip && run.result == [2, 0, 1])  // only Finish is left
}

// After Save, only the knobs with no column are asked for: the others keep theirs, before and between.
@Test func calibrationOfOnlyNewKnobs() {
    var run = Calibrator(saved: [0, 3, 2, 4, nil], onlyNew: true)
    #expect(run.found == [0, 3, 2, 4] && run.knob == 4 && run.first == 4 && run.phase == 0 && !run.canSkip)
    run.feed([500, 500, 500, 500, 500], at: 0)
    run.feed([500, 1023, 500, 500, 500], at: 0.03)
    #expect(run.found == [0, 3, 2, 4, 1] && run.phase == 1)
    run.skip()
    run.feed([500, 1023, 500, 500, 500], at: 0.06)
    #expect(run.full && run.result == [0, 3, 2, 4, 1])  // every input has its knob now

    var middle = Calibrator(saved: [0, nil, 2], onlyNew: true)
    #expect(middle.knob == 1)
    middle.feed([500, 500, 500, 500], at: 0)
    middle.feed([500, 500, 500, 1023], at: 0.03)
    middle.skip()
    #expect(middle.found == [0, 3, 2] && middle.knob == 3)  // knob C kept its column without being asked
}

// Only a found knob can be skipped. With D and E needing calibration: D, not found, has Finish, which
// leaves both as they were. Once D is found it has Skip and keeps its column, and E still needs it.
@Test func onlyAFoundKnobCanBeSkipped() {
    var run = Calibrator(saved: [0, 3, 2, nil, nil], onlyNew: true)
    #expect(run.knob == 3 && !run.canSkip && run.result == [0, 3, 2, nil, nil])
    run.feed([500, 500, 500, 500, 500], at: 0)
    run.feed([500, 1023, 500, 500, 500], at: 0.03)
    #expect(run.phase == 1 && run.canSkip)
    run.skip()
    #expect(run.knob == 4 && !run.canSkip && run.result == [0, 3, 2, 1, nil])
}

// A knob set up before counts as found: it can be skipped while it's asked for, keeping its column,
// unless this run has found that column on another knob.
@Test func calibrationSkipsKnobsAlreadySetUp() {
    var run = Calibrator(saved: [2, nil, 0, 3])
    #expect(run.canSkip)
    run.skip()
    #expect(run.found == [2] && run.knob == 1 && run.phase == 0)
    #expect(!run.canSkip)  // knob B has no column yet
    run.feed([500, 500, 500, 500], at: 0)
    run.feed([500, 500, 500, 1023], at: 0.03)
    #expect(run.found == [2, 3] && run.phase == 1)  // knob B is on column 3, which knob D had
    run.skip()
    #expect(run.knob == 2 && run.canSkip)
    run.skip()
    #expect(run.found == [2, 3, 0] && run.knob == 3 && !run.canSkip)  // column 3 is knob B's now
    #expect(run.result == [2, 3, 0, nil])
}
