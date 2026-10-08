import Testing
@testable import TheeJ

// A DIY board's wizard, fed frames that each change one column of the frame before.
private struct Run {
    var wizard: CalWizard
    var frame: [Int]

    init(_ board: Board, _ controls: [Int], _ frame: [Int]) {
        wizard = CalWizard(board, controls: controls)
        self.frame = frame
        wizard.feed(frame)
    }

    // Slides a column to a value in ten steps.
    mutating func move(_ column: Int, _ value: Int) {
        let from = frame[column]
        for step in 1...10 {
            frame[column] = from + (value - from) * step / 10
            wizard.feed(frame)
        }
    }
}

private func diy(_ knobs: Int, _ buttons: Int) -> Board {
    Board.make(id: "d1", name: "Desk", type: .diy, knobs: knobs, buttons: buttons, profileName: "Default")
}

@Test func wizardReadsBothEndsThenFindsEachPot() {
    var run = Run(diy(2, 0), [0, 1], [12, 1010, 9, 500])
    #expect(run.wizard.stage == .zero && run.wizard.order.count == 2)
    run.wizard.next()
    run.move(2, 1003)
    run.move(1, 2)  // the second knob's 100% is its low end: it is wired the other way round
    #expect(run.wizard.stage == .full)
    run.wizard.next()
    #expect(run.wizard.stage == .find && run.wizard.current == 0 && run.wizard.position == 0)
    run.move(2, 9)
    #expect(run.wizard.stage == .find && run.wizard.current == 1)
    run.move(1, 1010)
    #expect(run.wizard.done)
    #expect(run.wizard.result[0] == Control(kind: .knob, input: 2, min: 9, max: 1003))
    #expect(run.wizard.result[1] == Control(kind: .knob, input: 1, reverse: true, min: 2, max: 1010))
}

// Turning a knob to 0% before the first Next is getting ready, not the knob's turn.
@Test func wizardTakesNoMoveBeforeBothReadings() {
    var run = Run(diy(1, 0), [0], [100, 600])
    run.move(1, 1020)
    run.wizard.next()
    run.move(1, 30)
    run.wizard.next()
    run.move(1, 1020)
    #expect(run.wizard.done && run.wizard.result[0] == Control(kind: .knob, input: 1, reverse: true, min: 30, max: 1020))
}

@Test func wizardGoesBackToZeroWhenNothingMoved() {
    var run = Run(diy(1, 0), [0], [100, 600])
    run.wizard.next()
    run.wizard.next()
    #expect(run.wizard.stage == .zero && run.wizard.warning == .nothing)
    run.wizard.next()
    run.move(1, 0)
    run.wizard.next()
    run.wizard.redo()
    #expect(run.wizard.stage == .zero && run.wizard.warning == nil)
}

@Test func wizardWarnsOfTheWrongAndAnUnsweptControl() {
    var board = diy(2, 0)
    board.controls[0].input = 0
    var run = Run(board, [1], [20, 20, 20, 20])
    run.wizard.next()
    run.move(0, 900)
    run.move(1, 900)
    run.wizard.next()
    for i in 0..<50 {
        run.frame[1] = 900 - i % 5
        run.wizard.feed(run.frame)
    }
    #expect(run.wizard.stage == .find && run.wizard.warning == nil)  // jitter is no turn
    run.move(0, 20)
    #expect(run.wizard.warning == .wrong(0) && run.wizard.stage == .find)
    run.move(3, 900)
    #expect(run.wizard.warning == .unswept && run.wizard.stage == .find)
    run.move(3, 20)
    run.move(1, 20)
    #expect(run.wizard.done && run.wizard.result[1] == Control(kind: .knob, input: 1, min: 20, max: 900))
}

@Test func wizardTakesThreePressesOfOneButton() {
    var run = Run(diy(0, 1), [0], [500, 0, 0])
    #expect(run.wizard.stage == .press)  // a board of buttons skips both readings
    func press(_ column: Int) {
        run.move(column, 1023)
        run.move(column, 0)
    }
    press(1)
    press(2)
    #expect(run.wizard.warning == .mismatch && run.wizard.count == 0)
    press(2)
    press(2)
    #expect(run.wizard.count == 2 && run.wizard.warning == nil)
    press(2)
    #expect(run.wizard.done && run.wizard.result[0].input == 2)
}

@Test func wizardOnAMIDIBoard() {
    let pads = Board.make(id: "d2", name: "Pads", type: .midi, knobs: 1, buttons: 1, profileName: "Default")
    var wizard = CalWizard(pads, controls: [0, 1])
    var frame = Array(repeating: -1, count: mixerColumns)
    func feed(_ column: Int, _ value: Int) {
        frame[column] = value
        wizard.feed(frame)
    }
    // Already at 0%, the knob sends nothing before the first Next.
    wizard.next()
    for value in [8, 200, 600, 1023] { feed(7, value) }
    wizard.next()
    #expect(wizard.stage == .find)
    feed(7, 900)
    #expect(wizard.current == 1 && wizard.stage == .press)
    // A button's id may equal a pot's column: they are apart on a MIDI board.
    for _ in 0..<3 { wizard.press(7) }
    #expect(wizard.done && wizard.result == [Control(kind: .knob, input: 7), Control(kind: .button, input: 7)])
}

@Test func wizardSkipKeepsWhatWasThere() {
    var board = diy(0, 2)
    board.controls[0].input = 4
    var wizard = CalWizard(board, controls: [0, 1])
    wizard.skip()
    #expect(wizard.current == 1 && wizard.position == 1)
    wizard.skip()
    #expect(wizard.done && wizard.result == board.controls)
}
