import Darwin
import Foundation
import SQLite3

private final class MoveJournal {
    private let db: OpaquePointer
    private let clock = ISO8601DateFormatter()

    private init(_ db: OpaquePointer) {
        self.db = db
    }

    static func open(_ path: String) throws -> MoveJournal {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let details = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite connection unavailable"
            sqlite3_close(connection)
            throw Failure("Cannot open the move journal: \(details)")
        }
        let journal = MoveJournal(connection)
        sqlite3_busy_timeout(connection, 2000)
        try journal.exec("PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA secure_delete = ON")
        try journal.exec("""
            CREATE TABLE IF NOT EXISTS move_events (
                sequence INTEGER PRIMARY KEY,
                operation_id TEXT NOT NULL,
                record TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS move_events_by_operation ON move_events(operation_id, sequence);
            CREATE TABLE IF NOT EXISTS expired_move_ids (operation_id TEXT PRIMARY KEY) WITHOUT ROWID;
            """)
        return journal
    }

    deinit { sqlite3_close(db) }

    private var error: Failure { Failure("Move journal: \(String(cString: sqlite3_errmsg(db)))") }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func statement<T>(_ sql: String, values: [String], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error }
        defer { sqlite3_finalize(statement) }
        let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, copy) == SQLITE_OK else { throw error }
        }
        return try body(statement)
    }

    func latest(_ id: UUID) throws -> JSON? {
        try statement("SELECT record FROM move_events WHERE operation_id = ? ORDER BY sequence DESC LIMIT 1",
                      values: [id.uuidString]) { statement in
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw error }
            let data = Data(String(cString: value).utf8)
            guard let record = try JSONSerialization.jsonObject(with: data) as? JSON else {
                throw Failure("Invalid move journal entry.")
            }
            return record
        }
    }

    func expired(_ id: UUID) throws -> Bool {
        try statement("SELECT 1 FROM expired_move_ids WHERE operation_id = ?", values: [id.uuidString]) {
            let status = sqlite3_step($0)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error }
            return status == SQLITE_ROW
        }
    }

    func purge(before cutoff: Date, canExpire: (UUID, String?, String?) throws -> Bool) throws {
        try transaction {
            let ids = try statement("""
                SELECT operation_id, json_extract(record, '$.phase'), json_extract(record, '$.worker')
                FROM move_events
                JOIN (SELECT MAX(sequence) AS latest FROM move_events GROUP BY operation_id)
                  ON sequence = latest
                WHERE json_extract(record, '$.at') < ?
                """, values: [clock.string(from: cutoff)]) { statement in
                var ids: [UUID] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { return ids }
                    guard result == SQLITE_ROW, let column = sqlite3_column_text(statement, 0) else { throw error }
                    guard let id = UUID(uuidString: String(cString: column)) else { continue }
                    let phase = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                    let owner = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    if try canExpire(id, phase, owner) { ids.append(id) }
                }
            }
            for id in ids {
                try statement("INSERT OR IGNORE INTO expired_move_ids VALUES (?)", values: [id.uuidString]) {
                    guard sqlite3_step($0) == SQLITE_DONE else { throw error }
                }
                try statement("DELETE FROM move_events WHERE operation_id = ?", values: [id.uuidString]) {
                    guard sqlite3_step($0) == SQLITE_DONE else { throw error }
                }
            }
        }
    }

    @discardableResult
    func append(_ entry: JSON, preservingTimestamp: Bool = false) throws -> JSON {
        var entry = entry
        if !preservingTimestamp { entry["at"] = clock.string(from: Date()) }
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try statement("INSERT INTO move_events (operation_id, record) VALUES (?, ?)",
                             values: [entry["operationId"] as! String, String(decoding: data, as: UTF8.self)]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
            return entry
        }
    }
}

enum MovePhase: String {
    case preflight
    case applying
}

typealias MoveProgress = (MovePhase, JSON) throws -> Void

struct MoveRequest {
    let operationID: UUID
    let source: MailboxAddress
    let destination: MailboxAddress
    let id: Int
    let messageID: String
    let verifyArrival: Bool

    var arguments: JSON {
        ["operationId": operationID.uuidString, "source": source.json, "destination": destination.json,
         "id": id, "messageId": messageID, "verifyArrival": verifyArrival]
    }

    func matches(_ entry: JSON) throws -> Bool {
        let args = Arguments(values: entry)
        return try args.mailboxAddress("source") == source && args.mailboxAddress("destination") == destination &&
            entry["id"] as? Int == id && entry["messageId"] as? String == messageID &&
            args.boolean("verifyArrival") == verifyArrival
    }
}

final class MoveOperations {
    static let batchLimit = 50
    private static let queueLimit = 64
    private static let verificationLimit = 64
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MailMCP", isDirectory: true)
    private let automation: DispatchQueue
    private let verification: DispatchQueue
    private let verify: ((JSON) throws -> MoveVerification)?
    private var checking = Set<UUID>()
    private let directory: URL
    private let lock = NSLock()
    private let worker = UUID().uuidString
    private var journal: MoveJournal?
    private var active: Set<UUID> = []
    private var lease: FileHandle?
    private var uncommitted: [UUID: JSON] = [:]
    private var maintenance: DispatchSourceTimer?

    init(automation: DispatchQueue, directory: URL = MoveOperations.defaultDirectory,
         verification: DispatchQueue = DispatchQueue(label: "MailMCP.MoveVerification"),
         verify: ((JSON) throws -> MoveVerification)? = nil) {
        self.verification = verification
        self.verify = verify
        self.automation = automation
        self.directory = directory
    }

    func startMaintenance() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MailMCP.JournalMaintenance"))
        timer.schedule(deadline: .now(), repeating: .seconds(86_400), leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            do {
                try self?.purge(before: Date().addingTimeInterval(-90 * 86_400))
            } catch {
                CallTrace("journal_maintenance").log("purge_failed")
            }
        }
        maintenance = timer
        timer.resume()
    }

    func purge(before cutoff: Date) throws {
        try synchronized {
            let journal = try database()
            do { try migrateLegacy(into: journal) }
            catch { CallTrace("journal_maintenance").log("legacy_import_failed") }
            let protected = active.union(checking).union(uncommitted.keys)
            try journal.purge(before: cutoff) { id, phase, owner in
                guard !protected.contains(id) else { return false }
                if phase == "finished" || phase == "awaiting_verification" { return true }
                if let owner { return try !workerIsActive(owner) }
                return false
            }
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func database() throws -> MoveJournal {
        if let journal { return journal }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let resolved = realpath(directory.path, nil) else { throw Failure("Cannot resolve the move journal directory.") }
        defer { free(resolved) }
        let path = String(cString: resolved) + "/moves.sqlite3"
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot create the move journal (errno \(errno)).") }
        close(fd)
        let journal = try MoveJournal.open(path)
        self.journal = journal
        return journal
    }

    private var leasePath: String { directory.appendingPathComponent("move-worker.lock").path }

    private func acquireLease() throws {
        if lease != nil { return }
        let fd = open(leasePath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open the move worker lock (errno \(errno)).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("A separate MailMCP instance is handling moves.") }
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Data(worker.utf8))
        lease = file
    }

    private func workerIsActive(_ owner: String) throws -> Bool {
        let fd = open(leasePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return false }
        guard fd >= 0 else { throw Failure("Cannot check the move worker lock (errno \(errno)).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
        guard errno == EWOULDBLOCK else { throw Failure("Cannot check the move worker lock (errno \(errno)).") }
        let stamp = try file.read(upToCount: 36) ?? Data()
        return String(decoding: stamp, as: UTF8.self) == owner
    }

    private func legacyStatus(_ id: UUID) throws -> JSON? {
        let url = directory.appendingPathComponent("moves.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").reversed().lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON }
            .first { ($0["operationId"] as? String).flatMap(UUID.init(uuidString:)) == id }
    }

    private func migrateLegacy(into journal: MoveJournal) throws {
        let url = directory.appendingPathComponent("moves.jsonl")
        let data: String
        do {
            data = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        let records = try data.split(separator: "\n").map { line -> (UUID, JSON) in
            guard var record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON,
                  let id = (record["operationId"] as? String).flatMap(UUID.init(uuidString:)),
                  record["at"] is String else { throw Failure("Invalid legacy move journal entry.") }
            let verified = record["status"] as? String == "verified"
            record["operationId"] = id.uuidString
            record["status"] = verified ? "verified" : "failed"
            record["phase"] = "finished"
            record["outcome"] = verified ? "moved" : "unknown"
            record["safeToRetry"] = false
            return (id, record)
        }
        try journal.transaction {
            var skip: [UUID: Bool] = [:]
            for (id, record) in records {
                if skip[id] == nil { skip[id] = try journal.latest(id) != nil || journal.expired(id) }
                if skip[id] == false { try journal.append(record, preservingTimestamp: true) }
            }
        }
        // A concurrent migration may have removed the file after committing.
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    private func publicRecord(_ entry: JSON) -> JSON {
        var entry = entry
        entry.removeValue(forKey: "worker")
        return entry
    }

    private func status(_ id: UUID, journal: MoveJournal) throws -> JSON? {
        if let entry = uncommitted[id] { return publicRecord(entry) }
        if let entry = try journal.latest(id) {
            guard entry["status"] as? String == "pending", entry["phase"] as? String != "awaiting_verification", !active.contains(id),
                  let owner = entry["worker"] as? String, try !workerIsActive(owner) else {
                return publicRecord(entry)
            }
            return try journal.transaction {
                guard let latest = try journal.latest(id) else { return nil }
                guard latest["status"] as? String == "pending", latest["phase"] as? String != "awaiting_verification",
                      let currentOwner = latest["worker"] as? String, try !workerIsActive(currentOwner) else {
                    return publicRecord(latest)
                }
                let phase = latest["phase"] as? String
                let notStarted = phase == "queued" || phase == MovePhase.preflight.rawValue
                return try publicRecord(journal.append(latest.merging([
                    "status": "failed", "phase": "finished",
                    "outcome": notStarted ? "not_moved" : "unknown", "safeToRetry": notStarted,
                    "error": "The move worker stopped before recording a final result."
                ]) { _, new in new }))
            }
        }
        if try journal.expired(id) {
            return ["operationId": id.uuidString, "status": "expired", "safeToRetry": false]
        }
        guard var entry = try legacyStatus(id) else { return nil }
        if entry["status"] as? String != "verified" {
            entry["status"] = "failed"
            entry["outcome"] = "unknown"
            entry["safeToRetry"] = false
        }
        return entry
    }

    private func canRecheck(_ entry: JSON) -> Bool {
        entry["phase"] as? String == "awaiting_verification" || entry["outcome"] as? String == "unknown"
    }

    func status(_ id: UUID, recheck: Bool = false) throws -> JSON {
        try synchronized {
            guard let entry = try status(id, journal: database()) else { throw Failure("Move operation not found.") }
            if recheck && canRecheck(entry) {
                guard checking.contains(id) || checking.count < Self.verificationLimit else {
                    throw Failure("The verification queue is busy. The move remains recorded. Check again later.")
                }
                scheduleCheck(id, entry: entry)
            }
            var result = entry
            if checking.contains(id) { result["verificationInProgress"] = true }
            return result
        }
    }

    // Called under lock. Checks read Mail on a separate queue and never dispatch a move.
    private func scheduleCheck(_ id: UUID, entry: JSON) {
        guard let verify, canRecheck(entry),
              checking.count < Self.verificationLimit, checking.insert(id).inserted else { return }
        verification.async {
            let trace = CallTrace("move_verification", id: id)
            trace.log("started")
            let result = Result { try verify(entry) }
            self.synchronized {
                defer { self.checking.remove(id) }
                do {
                    let journal = try self.database()
                    try journal.transaction {
                        guard var latest = try journal.latest(id), self.canRecheck(latest) else { return }
                        switch result {
                        case .success(let check):
                            latest["verification"] = check.evidence
                            latest.removeValue(forKey: "verificationError")
                            if let arrived = check.destinationID {
                                latest.merge(["status": "verified", "phase": "finished", "outcome": "moved",
                                              "destinationId": arrived, "safeToRetry": false]) { _, new in new }
                                latest.removeValue(forKey: "error")
                            }
                        case .failure(let error):
                            latest["verificationError"] = error.localizedDescription
                        }
                        try journal.append(latest)
                    }
                    trace.log("completed")
                } catch {
                    trace.log("journal_write_failed")
                }
            }
        }
    }

    func submit(_ operationID: UUID, source: MailboxAddress, destination: MailboxAddress, id: Int,
                messageID: String, verifyArrival: Bool = false, execute: @escaping (MoveProgress) throws -> JSON) throws -> JSON {
        let request = MoveRequest(operationID: operationID, source: source, destination: destination,
                                  id: id, messageID: messageID, verifyArrival: verifyArrival)
        return try submit([request]) { _, progress in try execute(progress) }[0]
    }

    func submit(_ requests: [MoveRequest], execute: @escaping (JSON, MoveProgress) throws -> JSON) throws -> [JSON] {
        guard (1...Self.batchLimit).contains(requests.count) else {
            throw Failure("A batch must contain 1 to \(Self.batchLimit) moves.")
        }
        guard Set(requests.map(\.operationID)).count == requests.count else {
            throw Failure("Each move in a batch must have its own operationId.")
        }
        let sources = Dictionary(grouping: requests) {
            MailboxAddress(account: $0.source.account, path: $0.source.path)
        }
        guard sources.values.allSatisfy({ Set($0.map(\.id)).count == $0.count }) else {
            throw Failure("The same source message appears more than once in the batch.")
        }
        let destinations = Dictionary(grouping: requests) {
            MailboxAddress(account: $0.destination.account, path: $0.destination.path)
        }
        for items in destinations.values {
            let matching = Dictionary(grouping: items, by: \.messageID)
            guard !matching.values.contains(where: { $0.count > 1 && $0.contains(where: \.verifyArrival) }) else {
                throw Failure("verifyArrival requires distinct Message-IDs for moves to the same destination in a batch.")
            }
        }

        return try synchronized {
            let journal = try database()
            func existing(_ request: MoveRequest) throws -> JSON? {
                guard let entry = try status(request.operationID, journal: journal) else { return nil }
                if entry["status"] as? String != "expired", try !request.matches(entry) {
                    throw Failure("operationId \(request.operationID.uuidString) is already assigned to a different move.")
                }
                return entry
            }
            let replayed = try requests.compactMap(existing)
            if replayed.count == requests.count { return replayed }
            try acquireLease()
            defer { if active.isEmpty { lease = nil } }
            // Check again under the worker lease in case another instance just finished.
            let previous = try requests.map(existing)
            let count = previous.filter { $0 == nil }.count
            guard active.count + count <= Self.queueLimit else {
                throw Failure("The move queue has insufficient capacity. No new moves were queued.")
            }
            let entries = try journal.transaction {
                try zip(requests, previous).map { request, prior in
                    if let prior { return prior }
                    var pending = request.arguments
                    pending["status"] = "pending"
                    pending["phase"] = "queued"
                    pending["worker"] = worker
                    return try journal.append(pending)
                }
            }
            for (index, request) in requests.enumerated() where previous[index] == nil {
                schedule(request.operationID, entry: entries[index], execute: execute)
            }
            return entries.map(publicRecord)
        }
    }

    func takeOver(_ ids: [UUID], execute: @escaping (JSON, MoveProgress) throws -> JSON) throws {
        guard !ids.isEmpty else { return }
        try synchronized {
            guard active.isEmpty, ids.count <= Self.queueLimit, Set(ids).count == ids.count else {
                throw Failure("Invalid move handoff.")
            }
            let journal = try database()
            try acquireLease()
            defer { if active.isEmpty { lease = nil } }
            let entries = try journal.transaction {
                try ids.map { id in
                    guard var record = try journal.latest(id), record["status"] as? String == "pending",
                          ["queued", "preflight"].contains(record["phase"] as? String ?? "") else {
                        throw Failure("Move handoff includes an operation that may have been dispatched.")
                    }
                    record["phase"] = "queued"
                    record["worker"] = worker
                    return try journal.append(record)
                }
            }
            for (id, entry) in zip(ids, entries) {
                schedule(id, entry: entry, execute: execute)
            }
        }
    }

    // Called with the journal lock held, after the pending records have committed.
    private func schedule(_ id: UUID, entry: JSON, execute: @escaping (JSON, MoveProgress) throws -> JSON) {
        active.insert(id)
        automation.async {
            self.run(id, pending: entry) { progress in try execute(entry, progress) }
        }
    }

    private func run(_ id: UUID, pending: JSON, execute: (MoveProgress) throws -> JSON) {
        var entry = pending
        var dispatched = false
        let trace = CallTrace("move_worker", id: id)
        func progress(_ phase: MovePhase, _ details: JSON) throws {
            try synchronized {
                var updated = entry.merging(details) { _, new in new }
                updated["phase"] = phase.rawValue
                entry = try database().append(updated)
                if phase == .applying { dispatched = true }
            }
            trace.log(phase.rawValue)
        }
        let result: JSON
        do {
            try progress(.preflight, [:])
            result = try execute(progress)
        } catch {
            result = ["status": "failed", "outcome": dispatched ? "unknown" : "not_moved",
                      "safeToRetry": !dispatched, "error": error.localizedDescription]
        }
        entry.merge(result) { _, new in new }
        entry["phase"] = result["status"] as? String == "pending" ? "awaiting_verification" : "finished"

        synchronized {
            defer {
                active.remove(id)
                if active.isEmpty { lease = nil }
            }
            do {
                let saved = try database().append(entry)
                if saved["phase"] as? String == "awaiting_verification",
                   saved["receiptId"] is Int || saved["destinationBaselineIds"] is [Int] {
                    scheduleCheck(id, entry: saved)
                }
                trace.log("journal_\(entry["status"] as? String ?? "unknown")")
            } catch {
                trace.log("journal_write_failed")
                entry["auditError"] = error.localizedDescription
                uncommitted[id] = entry
            }
        }
    }
}
