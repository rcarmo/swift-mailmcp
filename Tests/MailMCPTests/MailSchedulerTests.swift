import XCTest
@testable import MailMCP

final class MailSchedulerTests: XCTestCase {
    func testTimeoutSuspendsNewEventsUntilOneRecoveryProbeSucceeds() throws {
        var time: TimeInterval = 0
        let scheduler = MailScheduler(now: { time }, sleep: { time += $0 })
        var probes = 0
        var sends = 0
        func probe() { probes += 1 }
        XCTAssertThrowsError(try scheduler.send(waitForRecovery: false, check: {}, probe: probe) {
            sends += 1
            throw MailEventTimeout(event: "getd")
        })
        XCTAssertThrowsError(try scheduler.send(waitForRecovery: false, check: {}, probe: probe) {
            sends += 1
        }) { XCTAssertTrue($0 is MailBusy) }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(probes, 0)
        try scheduler.send(waitForRecovery: true, check: {}, probe: probe) { sends += 1 }
        try scheduler.send(waitForRecovery: false, check: {}, probe: probe) { sends += 1 }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(sends, 3)
    }

    func testFailedProbeExtendsCooldownWithoutDispatchingEvent() throws {
        var time: TimeInterval = 0
        let scheduler = MailScheduler(now: { time }, sleep: { time += $0 })
        XCTAssertThrowsError(try scheduler.send(waitForRecovery: false, check: {}, probe: {}) {
            throw MailEventTimeout(event: "getd")
        })
        time = 2
        XCTAssertThrowsError(try scheduler.send(waitForRecovery: false, check: {}, probe: {
            throw MailEventTimeout(event: "getd")
        }) { XCTFail("An event reached Mail before recovery") }) {
            XCTAssertEqual(($0 as? MailBusy)?.retryAfter, 4)
        }
    }
    func testExpiredWaiterLeavesBeforeBlockedMailEventReturns() {
        let scheduler = MailScheduler()
        let occupied = expectation(description: "first event reached Mail")
        let expired = expectation(description: "second request expired")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            try? scheduler.send(waitForRecovery: false, check: {}, probe: {}) {
                occupied.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        wait(for: [occupied], timeout: 2)
        let ends = ProcessInfo.processInfo.systemUptime + 0.15
        DispatchQueue.global().async {
            do {
                try scheduler.send(waitForRecovery: false, check: {
                    if ProcessInfo.processInfo.systemUptime >= ends { throw Failure("deadline") }
                }, probe: {}) { XCTFail("Expired event reached Mail") }
            } catch { XCTAssertEqual(error.localizedDescription, "deadline") }
            expired.fulfill()
        }
        wait(for: [expired], timeout: 2)
        release.signal()
        XCTAssertNoThrow(try scheduler.send(waitForRecovery: false, check: {}, probe: {}) {})
    }

    func testNativeSendOverrunReturnsTimeoutAndPreventsLateDuplicateDispatch() {
        let transport = MailEventTransport()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        XCTAssertThrowsError(try transport.perform(event: "move", timeout: 0.1, prepare: {}) { _ in
            _ = release.wait(timeout: .now() + 3)
            return 123
        }) { XCTAssertTrue($0 is MailEventTimeout) }
        XCTAssertThrowsError(try transport.perform(event: "move", timeout: 0.1, prepare: {
            XCTFail("Second move reached the dispatch boundary")
        }) { _ in XCTFail("Two native sends overlapped") }) { XCTAssertTrue($0 is MailBusy) }
    }

}
