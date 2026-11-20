import Foundation

final class MailReads {
    private final class Flight {
        var followers = 0
        var result: Result<JSON, Error>?
    }

    private let condition = NSCondition()
    private var flights: [Data: Flight] = [:]
    private var discovery: (expires: TimeInterval, value: JSON)?

    typealias DateRow = (id: Int, date: Date)
    private var datePages: [UUID: (expires: TimeInterval, rows: [DateRow])] = [:]
    private var dateGeneration: UInt64 = 0

    func invalidateDates(_ mailboxes: [UUID]) {
        condition.lock()
        defer { condition.unlock() }
        dateGeneration &+= 1
        for id in mailboxes { datePages.removeValue(forKey: id) }
    }

    // Keep short-lived date snapshots for paged searches. Check the live count
    // before reuse and bound the total number of rows retained across accounts.
    func dates(in mailbox: UUID, count: Int, load: () throws -> [DateRow]) rethrows -> [DateRow] {
        condition.lock()
        let generation = dateGeneration
        let now = ProcessInfo.processInfo.systemUptime
        datePages = datePages.filter { $0.value.expires > now }
        if let page = datePages[mailbox], page.rows.count == count {
            condition.unlock()
            return page.rows
        }
        condition.unlock()
        let rows = try load()
        condition.lock()
        defer { condition.unlock() }
        if generation == dateGeneration, rows.count <= 50_000 {
            datePages.removeValue(forKey: mailbox)
            if rows.count + datePages.values.reduce(0, { $0 + $1.rows.count }) > 50_000 || datePages.count >= 64 {
                datePages.removeAll()
            }
            datePages[mailbox] = (ProcessInfo.processInfo.systemUptime + 10, rows)
        }
        return rows
    }

    func run(_ key: Data, cacheDiscovery: Bool, check: @escaping () throws -> Void,
             read: (@escaping () throws -> Void) throws -> JSON) throws -> JSON {
        try check()
        condition.lock()
        if cacheDiscovery, let discovery, discovery.expires > ProcessInfo.processInfo.systemUptime {
            condition.unlock()
            return discovery.value
        }
        if let flight = flights[key] {
            flight.followers += 1
            defer {
                flight.followers -= 1
                condition.unlock()
            }
            while flight.result == nil {
                try check()
                _ = condition.wait(until: Date().addingTimeInterval(0.1))
            }
            try check()
            return try flight.result!.get()
        }

        let flight = Flight()
        flights[key] = flight
        condition.unlock()
        let result = Result {
            try read {
                do {
                    try check()
                } catch {
                    self.condition.lock()
                    let stillNeeded = flight.followers > 0
                    self.condition.unlock()
                    if !stillNeeded { throw error }
                }
            }
        }
        condition.lock()
        flight.result = result
        flights.removeValue(forKey: key)
        if cacheDiscovery, case .success(let value) = result {
            discovery = (ProcessInfo.processInfo.systemUptime + 5, value)
        }
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }
}
