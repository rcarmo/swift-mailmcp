import XCTest
@testable import MailMCP

final class MailReadsTests: XCTestCase {
    func testIdenticalInFlightReadsShareTheResult() {
        let reads = MailReads()
        let key = Data("same-read".utf8)
        let leaderStarted = expectation(description: "leader started")
        let followerJoined = expectation(description: "follower joined")
        let bothFinished = expectation(description: "both callers finished")
        bothFinished.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { bothFinished.fulfill() }
            let result = try? reads.run(key, cacheDiscovery: false, check: {}) { _ in
                leaderStarted.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return ["count": 10]
            }
            XCTAssertEqual(result?["count"] as? Int, 10)
        }
        wait(for: [leaderStarted], timeout: 3)

        DispatchQueue.global().async {
            defer { bothFinished.fulfill() }
            var checks = 0
            let result = try? reads.run(key, cacheDiscovery: false, check: {
                checks += 1
                if checks == 2 { followerJoined.fulfill() }
            }) { _ in
                XCTFail("Follower issued a duplicate read")
                return [:]
            }
            XCTAssertEqual(result?["count"] as? Int, 10)
        }
        wait(for: [followerJoined], timeout: 3)
        release.signal()
        wait(for: [bothFinished], timeout: 3)
    }
    func testDateCacheChecksMailboxCountAndInvalidatesOnMove() {
        let reads = MailReads()
        let box = UUID()
        var loads = 0
        func index(_ count: Int) -> [MailReads.DateRow] {
            reads.dates(in: box, count: count) {
                loads += 1
                return Array(repeating: (loads, Date.distantPast), count: count)
            }
        }
        XCTAssertEqual(index(2).first?.id, 1)
        XCTAssertEqual(index(2).first?.id, 1)
        XCTAssertEqual(index(3).first?.id, 2)
        reads.invalidateDates([box])
        XCTAssertEqual(index(3).first?.id, 3)
    }

}
