import Foundation
import Testing
@testable import TheeJ

// A burst of movement lands as one write carrying the last value.
@Test func debounceKeepsTheLastValue() {
    var landed: [Int] = []
    for v in 1...3 { debounce(.brightness(0), on: ddcQueue) { landed.append(v) } }
    Thread.sleep(forTimeInterval: brightnessSettle * 2)
    ddcQueue.sync {}
    #expect(landed == [3])
}
