import Foundation
import SQLite3
import XCTest
@testable import MailMCP

final class MoveOperationsTests: XCTestCase {
    private let source = MailboxAddress(account: nil, path: ["Source"])
    private let destination = MailboxAddress(account: "account", path: ["Archive"])
    private var directory: URL!
    private var automation: DispatchQueue!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        automation = DispatchQueue(label: "test.move-worker")
    }

    override func tearDown() {
        automation.sync(flags: .barrier) {}
        try? FileManager.default.removeItem(at: directory)
    }

    func testAcknowledgesBeforeMailIsAvailableAndDoesNotReplayAnOperationID() throws {
        let operations = MoveOperations(automation: automation, directory: directory)
        let otherProcessView = MoveOperations(automation: automation, directory: directory)
        let operationID = UUID()
        let readerStarted = expectation(description: "Read holds the Mail queue")
        let releaseReader = DispatchSemaphore(value: 0)
        automation.async {
            readerStarted.fulfill()
            releaseReader.wait()
        }
        defer { releaseReader.signal() }
        wait(for: [readerStarted], timeout: 3)

        let applying = expectation(description: "Applying transition committed")
        let releaseMove = DispatchSemaphore(value: 0)
        defer { releaseMove.signal() }
        let pending = try operations.submit(operationID, source: source, destination: destination, id: 5, messageID: "key") { progress in
            try progress(.applying, [:])
            applying.fulfill()
            releaseMove.wait()
            return ["status": "verified", "outcome": "moved", "destinationId": 9]
        }
        XCTAssertEqual(pending["status"] as? String, "pending")
        XCTAssertEqual(pending["phase"] as? String, "queued")
        XCTAssertEqual(try otherProcessView.status(operationID)["phase"] as? String, "queued")
        let replay = try otherProcessView.submit(operationID, source: source, destination: destination, id: 5, messageID: "key") { _ in
            XCTFail("Duplicate operation was executed")
            return [:]
        }
        XCTAssertEqual(replay["operationId"] as? String, operationID.uuidString)
        XCTAssertThrowsError(try operations.submit(operationID, source: source, destination: destination, id: 6, messageID: "key") { _ in [:] })

        releaseReader.signal()
        wait(for: [applying], timeout: 3)
        XCTAssertEqual(try otherProcessView.status(operationID)["phase"] as? String, "applying")
        releaseMove.signal()
        automation.sync(flags: .barrier) {}
        let result = try otherProcessView.status(operationID)
        XCTAssertEqual(result["status"] as? String, "verified")
        XCTAssertEqual(result["destinationId"] as? Int, 9)
    }

    func testFailureDistinguishesPreflightFromAnUncertainTransfer() throws {
        let operations = MoveOperations(automation: automation, directory: directory)
        let preflight = UUID()
        let applying = UUID()
        _ = try operations.submit(preflight, source: source, destination: destination, id: 5, messageID: "key") { _ in
            throw Failure("Mailbox unavailable")
        }
        _ = try operations.submit(applying, source: source, destination: destination, id: 5, messageID: "key") { progress in
            try progress(.applying, [:])
            throw Failure("Mail timed out")
        }
        automation.sync(flags: .barrier) {}
        let reader = MoveOperations(automation: automation, directory: directory)
        let before = try reader.status(preflight)
        let during = try reader.status(applying)
        XCTAssertEqual(before["status"] as? String, "failed")
        XCTAssertEqual(before["outcome"] as? String, "not_moved")
        XCTAssertEqual(before["safeToRetry"] as? Bool, true)
        XCTAssertEqual(during["status"] as? String, "failed")
        XCTAssertEqual(during["outcome"] as? String, "unknown")
        XCTAssertEqual(during["safeToRetry"] as? Bool, false)
    }
    func testInterruptedOperationsRecoverWithoutReplayingMail() throws {
        let operations = MoveOperations(automation: automation, directory: directory)
        XCTAssertThrowsError(try operations.status(UUID()))

        let queued = UUID()
        let preparing = UUID()
        let applying = UUID()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("moves.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for (id, phase) in [(queued, "queued"), (preparing, "preflight"), (applying, "applying")] {
            let record: JSON = ["operationId": id.uuidString, "worker": UUID().uuidString,
                                "status": "pending", "phase": phase]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            let sql = "INSERT INTO move_events (operation_id, record) VALUES ('\(id.uuidString)', '\(text)')"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        XCTAssertThrowsError(try operations.takeOver([preparing, applying]) { _, _ in
            XCTFail("Unsafe handoff started work")
            return [:]
        })
        try operations.takeOver([preparing]) { record, progress in
            XCTAssertEqual(record["operationId"] as? String, preparing.uuidString)
            try progress(.applying, [:])
            return ["status": "verified", "outcome": "moved"]
        }
        automation.sync {}
        XCTAssertEqual(try operations.status(queued)["outcome"] as? String, "not_moved")
        XCTAssertEqual(try operations.status(preparing)["status"] as? String, "verified")
        XCTAssertEqual(try operations.status(applying)["outcome"] as? String, "unknown")
        let restarted = MoveOperations(automation: automation, directory: directory)
        XCTAssertEqual(try restarted.status(applying)["status"] as? String, "failed")
        XCTAssertEqual(try restarted.status(queued)["safeToRetry"] as? Bool, true)
    }

    func testAcceptedMoveSurvivesRestartAndSlowCheckDoesNotBlockDispatch() throws {
        let checkQueue = DispatchQueue(label: "test.verify")
        let started = expectation(description: "verification is waiting on Mail")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let operations = MoveOperations(automation: automation, directory: directory, verification: checkQueue) { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 4)
            return MoveVerification(destinationID: 99, evidence: ["kind": "move_receipt"])
        }
        let first = UUID(), second = UUID()
        _ = try operations.submit(first, source: source, destination: destination, id: 1, messageID: "a") { progress in
            try progress(.applying, [:])
            return ["status": "pending", "outcome": "accepted", "safeToRetry": false, "receiptId": 99]
        }
        wait(for: [started], timeout: 2)
        XCTAssertEqual(try operations.status(first, recheck: true)["verificationInProgress"] as? Bool, true)
        _ = try operations.submit(second, source: source, destination: destination, id: 2, messageID: "b") { progress in
            try progress(.applying, [:])
            return ["status": "pending", "outcome": "accepted", "safeToRetry": false]
        }
        automation.sync {}
        let restarted = MoveOperations(automation: automation, directory: directory, verification: checkQueue) { _ in
            .compare(matchingIDs: [73], baseline: nil)
        }
        XCTAssertEqual(try restarted.status(second)["phase"] as? String, "awaiting_verification")
        XCTAssertEqual(try restarted.submit(second, source: source, destination: destination, id: 2, messageID: "b") { _ in
            XCTFail("Accepted operation was dispatched twice")
            return [:]
        }["outcome"] as? String, "accepted")
        release.signal()
        _ = try restarted.status(second, recheck: true)
        checkQueue.sync {}
        XCTAssertEqual(try restarted.status(first)["destinationId"] as? Int, 99)
        let inconclusive = try restarted.status(second)
        XCTAssertEqual(inconclusive["status"] as? String, "pending")
        XCTAssertEqual(inconclusive["safeToRetry"] as? Bool, false)
        XCTAssertEqual((inconclusive["verification"] as? JSON)?["matchingDestinationIds"] as? [Int], [73])
    }

    func testUnknownDispatchCanBeReconciledWithoutAnotherMove() throws {
        let checkQueue = DispatchQueue(label: "test.verify")
        let operations = MoveOperations(automation: automation, directory: directory, verification: checkQueue) { record in
            .compare(matchingIDs: [7, 8], baseline: record["destinationBaselineIds"] as? [Int])
        }
        let id = UUID()
        _ = try operations.submit(id, source: source, destination: destination, id: 1, messageID: "key",
                                  verifyArrival: true) { progress in
            try progress(.applying, ["destinationBaselineIds": [7]])
            throw Failure("Mail reply timed out")
        }
        automation.sync {}
        XCTAssertEqual(try operations.status(id)["outcome"] as? String, "unknown")
        _ = try operations.status(id, recheck: true)
        checkQueue.sync {}
        XCTAssertEqual(try operations.status(id)["destinationId"] as? Int, 8)
        XCTAssertEqual(try operations.status(id)["safeToRetry"] as? Bool, false)
    }

    func testPurgeRemovesHistoryButKeepsUUIDReservedAndPreservesQueue() throws {
        let operations = MoveOperations(automation: automation, directory: directory)
        let expired = UUID()
        let live = UUID()
        _ = try operations.submit(expired, source: source, destination: destination, id: 1, messageID: "key") { progress in
            try progress(.applying, [:])
            return ["status": "pending", "outcome": "accepted"]
        }
        automation.sync {}
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = UUID()
        let legacyEntry: JSON = ["operationId": legacy.uuidString, "status": "verified", "at": "2020-01-01T00:00:00Z"]
        let legacyURL = directory.appendingPathComponent("moves.jsonl")
        try JSONSerialization.data(withJSONObject: legacyEntry).write(to: legacyURL)
        let release = DispatchSemaphore(value: 0)
        automation.async { _ = release.wait(timeout: .now() + 3) }
        defer { release.signal() }
        _ = try operations.submit(live, source: source, destination: destination, id: 2, messageID: "other") { _ in
            ["status": "failed", "outcome": "not_moved"]
        }
        try operations.purge(before: Date().addingTimeInterval(60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try operations.status(legacy)["status"] as? String, "expired")
        XCTAssertEqual(try operations.status(live)["phase"] as? String, "queued")
        let result = try operations.submit(expired, source: source, destination: destination, id: 1, messageID: "key") { _ in
            XCTFail("Purged operation executed again")
            return [:]
        }
        XCTAssertEqual(result["status"] as? String, "expired")
        XCTAssertEqual(result["safeToRetry"] as? Bool, false)
        XCTAssertNil(result["messageId"])
        XCTAssertNil(result["source"])
    }

    func testPreexistingDestinationCopiesDoNotProveArrival() {
        XCTAssertNil(MoveVerification.compare(matchingIDs: [4], baseline: nil).destinationID)
        XCTAssertNil(MoveVerification.compare(matchingIDs: [4], baseline: [4]).destinationID)
        XCTAssertNil(MoveVerification.compare(matchingIDs: [5], baseline: [4]).destinationID)
        XCTAssertNil(MoveVerification.compare(matchingIDs: [4, 5, 6], baseline: [4]).destinationID)
        XCTAssertEqual(MoveVerification.compare(matchingIDs: [4, 5], baseline: [4]).destinationID, 5)
        XCTAssertEqual(MoveVerification.compare(matchingIDs: [5], baseline: []).destinationID, 5)
    }

}
