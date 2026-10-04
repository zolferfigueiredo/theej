import Foundation
import Testing
@testable import TheeJ

@Test func nextPatchVersion() {
    #expect(nextPatch("1.7.0") == "1.7.1")
    #expect(nextPatch("0.9") == "0.10")
    #expect(nextPatch("?") == "1")
}

@Test(arguments: [
    ("0.1.3", "0.1.2", true),
    ("0.1.10", "0.1.9", true),  // numeric, not alphabetical
    ("1.0.0", "0.9.9", true),
    ("0.1.2", "0.1.2", false),
    ("0.1.1", "0.1.2", false),
])
func newerVersion(remote: String, local: String, expected: Bool) {
    #expect(isNewer(remote, than: local) == expected)
}

@Test func updateCheckSchedule() {
    let now = Date.now, hour: TimeInterval = 3600, day = 24 * hour
    #expect(updateCheckIsDue(last: nil, every: day, now: now))
    #expect(!updateCheckIsDue(last: nil, every: 0, now: now))
    #expect(!updateCheckIsDue(last: now - 23 * hour, every: day, now: now))
    #expect(updateCheckIsDue(last: now - 25 * hour, every: day, now: now))
    #expect(!updateCheckIsDue(last: now - 6 * day, every: 7 * day, now: now))
    #expect(updateCheckIsDue(last: now - 7 * day, every: 7 * day, now: now))
}
