import Testing
@testable import TheeJ

// Turns the knob on `column` through its three turning steps and its sweeps, the others at rest.
private func clean(_ run: inout Calibrator, _ column: Int, _ width: Int, _ clock: inout Double) {
    var line = Array(repeating: 500, count: width)
    var turning = 400
    while (1...3).contains(run.phase) {
        turning = 1000 - turning
        line[column] = turning
        clock += 0.03
        run.feed(line, at: clock)
    }
    while run.phase == 4 {
        for value in [0, 1023] { line[column] = value; clock += 0.03; run.feed(line, at: clock) }
    }
}

// Calibration finds the knob that swings, times only while it turns, counts sweeps, then asks for the
// next knob until every input has one.
@Test func calibrationRun() {
    var run = Calibrator()
    var clock = 0.0
    func tick(_ values: [Int]) { clock += 0.03; run.feed(values, at: clock) }
    tick([500, 500, 500])
    tick([520, 500, 100])
    #expect(run.phase == 0)  // column 2 has only swung 400
    tick([520, 500, 1000])
    #expect(run.found == [2] && run.phase == 1 && !run.paused)
    tick([520, 500, 1000])
    #expect(!run.paused)  // a step doesn't open on "paused" before the knob has had a second
    for _ in 0..<1000 { tick([520, 500, 1000]) }  // 30 seconds untouched
    #expect(run.phase == 1 && run.left == Calibrator.turnSeconds && run.paused)
    tick([520, 500, 600])
    #expect(!run.paused)
    var turning = 400
    while run.phase < 4 { turning = 1000 - turning; tick([520, 500, turning]) }
    #expect(abs(clock - 30 - 3 * Calibrator.turnSeconds) < 1)
    for _ in 0..<Calibrator.sweepsNeeded { tick([520, 500, 0]); tick([520, 500, 1023]) }
    #expect(run.knob == 1 && run.phase == 0)
    tick([520, 500, 0])
    tick([520, 500, 1023])
    #expect(run.phase == 0 && run.wrongKnob == 0)  // column 2 is knob A, so knob B cannot claim it
    tick([0, 500, 1023])
    #expect(run.found == [2, 0] && run.knob == 1 && run.phase == 1 && run.wrongKnob == nil)
    #expect(!run.canSkip && run.result == [2])  // a new knob can't be skipped, and isn't done part way
    clean(&run, 0, 3, &clock)
    #expect(run.knob == 2 && run.phase == 0 && run.result == [2, 0])
    run.skip()
    #expect(run.knob == 2 && run.phase == 0)  // nothing to skip: knob C needs calibrating
    tick([500, 0, 1023])
    tick([500, 1023, 1023])
    #expect(run.found == [2, 0, 1])
    clean(&run, 1, 3, &clock)
    tick([500, 1023, 1023])
    #expect(run.full && run.phase == 0 && !run.canSkip && run.result == [2, 0, 1])  // only Finish is left
}

// After Save, only the knobs with no column are asked for: the others keep theirs, before and between.
@Test func calibrationOfOnlyNewKnobs() {
    var clock = 0.03
    var run = Calibrator(saved: [0, 3, 2, 4, nil], onlyNew: true)
    #expect(run.found == [0, 3, 2, 4] && run.knob == 4 && run.first == 4 && run.phase == 0 && !run.canSkip)
    run.feed([500, 500, 500, 500, 500], at: 0)
    run.feed([500, 1023, 500, 500, 500], at: clock)
    #expect(run.found == [0, 3, 2, 4, 1] && run.phase == 1)
    clean(&run, 1, 5, &clock)
    run.feed([500, 1023, 500, 500, 500], at: clock + 0.03)
    #expect(run.full && run.result == [0, 3, 2, 4, 1])  // every input has its knob now

    var middle = Calibrator(saved: [0, nil, 2], onlyNew: true)
    #expect(middle.knob == 1)
    middle.feed([500, 500, 500, 500], at: 0)
    middle.feed([500, 500, 500, 1023], at: 0.03)
    clean(&middle, 3, 4, &clock)
    #expect(middle.found == [0, 3, 2] && middle.knob == 3)  // knob C kept its column without being asked
}

// The case that went wrong: with D and E needing calibration, D was found, and stopping during its turns
// counted it as calibrated. D can't be skipped, and Finish there leaves both D and E as they were.
@Test func stoppingPartWayLeavesNewKnobsNeedingCalibration() {
    var run = Calibrator(saved: [0, 3, 2, nil, nil], onlyNew: true)
    #expect(run.knob == 3 && !run.canSkip)
    run.feed([500, 500, 500, 500, 500], at: 0)
    run.feed([500, 1023, 500, 500, 500], at: 0.03)
    #expect(run.phase == 1 && !run.canSkip && run.result == [0, 3, 2, nil, nil])
}

// A knob calibrated before can be skipped, keeping its column, unless this run has found that column on
// another knob. One that needs calibrating can't: the button is Finish.
@Test func calibrationSkipsKnobsAlreadySetUp() {
    var clock = 0.03
    var run = Calibrator(saved: [2, nil, 0, 3])
    #expect(run.canSkip)
    run.skip()
    #expect(run.found == [2] && run.knob == 1 && run.phase == 0)
    #expect(!run.canSkip)  // knob B has no column yet
    run.feed([500, 500, 500, 500], at: 0)
    run.feed([500, 500, 500, 1023], at: clock)
    #expect(run.found == [2, 3] && run.phase == 1 && !run.canSkip)  // knob B is on column 3, which D had
    clean(&run, 3, 4, &clock)
    #expect(run.knob == 2 && run.canSkip)
    run.skip()
    #expect(run.found == [2, 3, 0] && run.knob == 3 && !run.canSkip)  // column 3 is knob B's now
    #expect(run.result == [2, 3, 0, nil])
}
