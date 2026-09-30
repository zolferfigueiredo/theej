import Foundation
import Testing
@testable import TheeJ

// A burst of movement lands as one write carrying the last value.
@Test func debounceKeepsTheLastValue() {
    var landed: [Int] = []
    let queue = DispatchQueue(label: "debounce")
    for v in 1...3 { debounce(.brightness(0), on: queue, after: 0.05) { landed.append(v) } }
    Thread.sleep(forTimeInterval: 0.1)
    queue.sync {}
    #expect(landed == [3])
}

// Each speed waits less than the one before it, and none less than a wiper dropout lasts.
@Test func speedsStayAboveTheWiperDropout() {
    let settles = Speed.allCases.map(\.settle)
    #expect(settles == settles.sorted(by: >))
    #expect(settles.allSatisfy { $0 > 0.11 })
}
