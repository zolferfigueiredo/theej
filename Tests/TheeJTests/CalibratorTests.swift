import Testing
@testable import TheeJ

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
    #expect(run.found == [2] && run.phase == 1)
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
    run.skip()
    #expect(run.knob == 2 && run.phase == 0 && !run.full)
    run.skip()
    #expect(run.knob == 2 && run.phase == 0)  // nothing to skip until knob C is found
    tick([0, 0, 1023])
    tick([0, 1023, 1023])
    #expect(run.found == [2, 0, 1])
    run.skip()
    tick([0, 1023, 1023])
    #expect(run.full && run.phase == 0)  // every input has its knob, so only Finish is left
}
