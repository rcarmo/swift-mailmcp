import Foundation

/// The Mail scripting handler runs on Mail's UI thread. Schedule one event at a
/// time and release the slot between events so another request can make progress.
final class MailScheduler {
    private let admission = NSCondition()
    private var occupied = false
    private var waiters: [UUID] = []
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private var cooldownUntil: TimeInterval?
    private var failures = 0
    private var slowRanges: [UUID: TimeInterval] = [:]

    func useRange(in mailbox: UUID) -> Bool {
        admission.lock()
        defer { admission.unlock() }
        guard let expires = slowRanges[mailbox] else { return true }
        return expires <= now()
    }

    func recordSlowRange(in mailbox: UUID) {
        admission.lock()
        defer { admission.unlock() }
        let time = now()
        slowRanges = slowRanges.filter { $0.value > time }
        slowRanges[mailbox] = time + 60
    }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) {
        self.now = now
        self.sleep = sleep
    }

    func send<T>(waitForRecovery: Bool, check: () throws -> Void, probe: () throws -> Void,
                 event: () throws -> T) throws -> T {
        var waited = false
        while true {
            do {
                return try withSlot(check: check) {
                    try check()
                    if let until = cooldownUntil {
                        let remaining = until - now()
                        guard remaining <= 0 else { throw MailBusy(retryAfter: remaining) }
                        do {
                            try probe()
                            failures = 0
                            cooldownUntil = nil
                        } catch {
                            backOff()
                            throw MailBusy(retryAfter: max(1, (cooldownUntil ?? now()) - now()))
                        }
                    }
                    try check()
                    do {
                        return try event()
                    } catch {
                        if error is MailEventTimeout { backOff() }
                        throw error
                    }
                }
            } catch let busy as MailBusy where waitForRecovery && !waited {
                // Sleep outside the event queue so interactive reads can get a prompt busy reply.
                waited = true
                let resume = now() + busy.retryAfter
                while resume > now() {
                    try check()
                    sleep(min(0.1, max(0, resume - now())))
                }
            }
        }
    }

    // Never hold the admission lock while an Apple Event waits for Mail. A
    // queued reader can reach its own deadline even if the current sender stalls.
    private func withSlot<T>(check: () throws -> Void, body: () throws -> T) throws -> T {
        let ticket = UUID()
        admission.lock()
        waiters.append(ticket)
        do {
            while occupied || waiters.first != ticket {
                try check()
                _ = admission.wait(until: Date().addingTimeInterval(0.1))
            }
            try check()
        } catch {
            waiters.removeAll { $0 == ticket }
            admission.broadcast()
            admission.unlock()
            throw error
        }
        waiters.removeFirst()
        occupied = true
        admission.unlock()
        defer {
            admission.lock()
            occupied = false
            admission.broadcast()
            admission.unlock()
        }
        return try body()
    }

    private func backOff() {
        failures = min(failures + 1, 4)
        cooldownUntil = now() + Double(1 << failures)
    }
}

struct MailBusy: LocalizedError {
    let retryAfter: TimeInterval
    var errorDescription: String? { "Mail is busy recovering from a timeout. Retry in about \(Int(ceil(retryAfter))) seconds." }
}

/// Bounds the caller's wait even if the native send outlives its timeout.
/// The outstanding native call owns the slot until it actually returns.
final class MailEventTransport {
    static let shared = MailEventTransport()
    private let available = DispatchSemaphore(value: 1)
    private let sender = DispatchQueue(label: "MailMCP.NativeAppleEvent")

    private final class Reply<T> {
        var result: Result<T, Error>?
        let ready = DispatchSemaphore(value: 0)
    }

    func perform<T>(event: String, timeout: TimeInterval, prepare: () throws -> Void,
                    send: @escaping (TimeInterval) throws -> T) throws -> T {
        guard available.wait(timeout: .now()) == .success else { throw MailBusy(retryAfter: 1) }
        let deadline = DispatchTime.now() + timeout
        do { try prepare() } catch {
            available.signal()
            throw error
        }
        let reply = Reply<T>()
        sender.async {
            reply.result = Result {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else { throw MailEventTimeout(event: event) }
                return try send(Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
            }
            self.available.signal()
            reply.ready.signal()
        }
        guard reply.ready.wait(timeout: deadline) == .success else { throw MailEventTimeout(event: event) }
        return try reply.result!.get()
    }
}
