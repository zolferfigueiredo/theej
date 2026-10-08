#if canImport(AppKit)
import CoreGraphics
import Testing
@testable import TheeJ

// What the engine would have set, in place of this Mac's volume.
private final class Recorder {
    var applied: [(jobs: [Target], scalar: Float32, hud: Bool)] = []

    func apply(_ jobs: [Target], _ scalar: Float32, _ settle: Double, _ shown: inout Set<CGDirectDisplayID>, _ hud: Bool) {
        applied.append((jobs, scalar, hud))
    }
}

// Each test has a board id of its own, since unmuteAll finds a board's state by it.
private func desk(_ id: String) -> Board {
    var board = Board.make(id: id, name: "Desk", type: .diy, knobs: 2, profileName: "Default")
    board.controls[0].input = 0
    board.controls[1].input = 1
    board.profiles[0].jobs = [[.master], [.microphone]]
    return board
}

@Test func theFirstReadingIsOnlyABaselineAndUnknownValuesWait() {
    let recorder = Recorder()
    let state = BoardState()
    let board = desk("e1")
    handle([-1, 512], of: board, state, calibrating: false, apply: recorder.apply)
    #expect(recorder.applied.isEmpty)
    handle([-1, 700], of: board, state, calibrating: false, apply: recorder.apply)
    #expect(recorder.applied.map(\.jobs) == [[.microphone]])
    handle([-1, 703], of: board, state, calibrating: false, apply: recorder.apply)  // under 1%
    #expect(recorder.applied.count == 1)
}

@Test func aMuteHoldsTheControlAndUnmutingPutsItBack() {
    let recorder = Recorder()
    let state = BoardState()
    let board = desk("e2")
    handle([500, -1], of: board, state, calibrating: false, apply: recorder.apply)
    handle([1023, -1], of: board, state, calibrating: false, apply: recorder.apply)
    toggleMute(board, 0, key: 9, state, apply: recorder.apply)
    #expect(state.muted == [0])
    handle([0, -1], of: board, state, calibrating: false, apply: recorder.apply)
    toggleMute(board, 0, key: 9, state, apply: recorder.apply)
    // The move, the mute, then the fader's new place as it unmutes.
    #expect(recorder.applied.map(\.scalar) == [1, 0, 0] && state.muted.isEmpty)
}

@Test func unmutingEveryControlShowsNoHUD() {
    let recorder = Recorder()
    let state = BoardState()
    let board = desk("e3")
    boardStates[board.id] = state
    defer { boardStates[board.id] = nil }
    handle([500, -1], of: board, state, calibrating: false, apply: recorder.apply)
    handle([1023, -1], of: board, state, calibrating: false, apply: recorder.apply)
    toggleMute(board, 0, key: 9, state, apply: recorder.apply)
    unmuteAll(board, apply: recorder.apply)
    #expect(recorder.applied.last?.scalar == 1 && recorder.applied.last?.hud == false && state.muted.isEmpty)
}

@Test func calibratingTracksWithoutApplying() {
    let recorder = Recorder()
    let state = BoardState()
    let board = desk("e4")
    handle([100, 100], of: board, state, calibrating: true, apply: recorder.apply)
    handle([900, 900], of: board, state, calibrating: true, apply: recorder.apply)
    #expect(recorder.applied.isEmpty && state.lastApplied[0] != nil)
}
#endif
