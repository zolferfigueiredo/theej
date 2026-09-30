import Testing
@testable import TheeJ

// Calibration finds the knob that swings, times only while it turns, then counts sweeps.
@Test func calibrationRun() {
    var run = Calibrator(knobs: 2)
    var clock = 0.0
    func tick(_ values: [Int]) { clock += 0.03; run.feed(values, at: clock) }
    tick([500, 500, 500])
    tick([520, 500, 100])
    #expect(run.phase == 0)  // column 2 has only swung 400
    tick([520, 500, 1000])
    #expect(run.found == [2, nil] && run.phase == 1)
    for _ in 0..<1000 { tick([520, 500, 1000]) }  // 30 seconds untouched
    #expect(run.phase == 1 && run.left == Calibrator.turnSeconds)
    var turning = 400
    while run.phase < 4 { turning = 1000 - turning; tick([520, 500, turning]) }
    #expect(abs(clock - 30 - 3 * Calibrator.turnSeconds) < 1)
    for _ in 0..<Calibrator.sweepsNeeded { tick([520, 500, 0]); tick([520, 500, 1023]) }
    #expect(run.knob == 1 && run.phase == 0)
    tick([520, 500, 0])
    tick([520, 500, 1023])
    #expect(run.phase == 0)  // column 2 is taken, so knob B cannot claim it
    run.skip()
    #expect(run.done && run.found == [2, nil])
}

@Test func calibratedColumnsKeepTheOnesNotFound() {
    #expect(calibrated([0, 2, 4], found: [2, nil, nil]) == [2, nil, 4])
}
