import Foundation
import Testing
@testable import TheeJ

// A burst of movement lands as one write carrying the last value. It waits for that write rather than for a
// fixed time, which a busy CI runner can outlast; an earlier one not cancelled would have run before it.
@Test func debounceKeepsTheLastValue() {
    var landed: [Int] = []
    let queue = DispatchQueue(label: "debounce")
    let last = DispatchSemaphore(value: 0)
    for v in 1...3 { debounce(.brightness(0), on: queue, after: 0.05) { landed.append(v); if v == 3 { last.signal() } } }
    #expect(last.wait(timeout: .now() + 5) == .success)
    queue.sync {}
    #expect(landed == [3])
}

// Each speed waits less than the one before it, and none less than a wiper dropout lasts.
@Test func speedsStayAboveTheWiperDropout() {
    let settles = Speed.allCases.map(\.settle)
    #expect(settles == settles.sorted(by: >))
    #expect(settles.allSatisfy { $0 > 0.11 })
}
