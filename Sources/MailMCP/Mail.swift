import AppKit
import Carbon
import CryptoKit

typealias JSON = [String: Any]
typealias Descriptor = NSAppleEventDescriptor

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct MailObjectNotFound: LocalizedError {
    var errorDescription: String? { "Mail object was not found (-1728)." }
}

private struct MailReplyError: LocalizedError {
    let event: String
    let status: Int
    var errorDescription: String? { "Mail Apple Event \(event) returned error \(status)." }
}

struct MailEventTimeout: LocalizedError {
    let event: String
    var errorDescription: String? { "Mail did not answer Apple Event \(event) before its deadline (-1712)." }
}

struct MoveVerification {
    let destinationID: Int?
    let evidence: JSON

    static func compare(matchingIDs: [Int], baseline: [Int]?) -> MoveVerification {
        let current = Set(matchingIDs)
        let previous = baseline.map(Set.init)
        let arrivals = previous.map { current.subtracting($0) }
        let proven = previous?.isSubset(of: current) == true && arrivals?.count == 1
        return MoveVerification(destinationID: proven ? arrivals?.first : nil, evidence: [
            "kind": proven ? "new_destination_id" : "destination_snapshot",
            "sourceMessageAbsent": true, "matchingDestinationIds": current.sorted()
        ])
    }
}

private func code(_ value: String) -> UInt32 {
    value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

private func spec(_ type: String, _ form: String, _ key: Descriptor, _ parent: Descriptor) -> Descriptor {
    let fields = Descriptor.record()
    fields.setDescriptor(Descriptor(typeCode: code(type)), forKeyword: code("want"))
    fields.setDescriptor(Descriptor(enumCode: code(form)), forKeyword: code("form"))
    fields.setDescriptor(key, forKeyword: code("seld"))
    fields.setDescriptor(parent, forKeyword: code("from"))
    return fields.coerce(toDescriptorType: code("obj "))!
}

private func property(_ name: String, _ parent: Descriptor) -> Descriptor {
    spec("prop", "prop", Descriptor(typeCode: code(name)), parent)
}

private func byIndex(_ type: String, _ index: Int, _ parent: Descriptor) -> Descriptor {
    spec(type, "indx", Descriptor(int32: Int32(index)), parent)
}

private func all(_ type: String, _ parent: Descriptor) -> Descriptor {
    var ordinal = code("all ")
    let key = Descriptor(descriptorType: code("abso"), bytes: &ordinal, length: MemoryLayout<UInt32>.size)!
    return spec(type, "indx", key, parent)
}

struct MailboxAddress: Hashable {
    let account: String?
    let path: [String]
    var mailboxID: UUID? = nil

    var json: JSON {
        var result: JSON = ["accountId": account as Any? ?? NSNull(), "path": path]
        if let mailboxID { result["mailboxId"] = mailboxID.uuidString }
        return result
    }
}

struct Mailbox {
    let account: String?
    let path: [String]
    let object: Descriptor
    let id: UUID

    init(account: String?, path: [String], object: Descriptor) {
        self.account = account
        self.path = path
        self.object = object

        var identity: [String?] = [account]
        if object.forKeyword(code("form"))?.enumCodeValue == code("ID  "),
           let key = object.forKeyword(code("seld")) {
            identity += ["mail-id", String(key.descriptorType), key.data.base64EncodedString()]
        } else {
            identity += ["path"] + path.map(Optional.some)
        }
        let encoded = try! JSONEncoder().encode(identity)
        var bytes = Array(SHA256.hash(data: encoded).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var json: JSON {
        MailboxAddress(account: account, path: path, mailboxID: id).json
    }
}

struct Message {
    let id: Int
    let messageID: String
    let subject: String
    let sender: String
    let sent: Date?
    let json: JSON

}

final class Mail {
    private let app = Descriptor(bundleIdentifier: "com.apple.mail")
    private let root = Descriptor.null()
    private let dateFormat = ISO8601DateFormatter()
    private var resolvedAccounts: [String: Descriptor] = [:]
    private let scheduler: MailScheduler?
    private let trace: CallTrace?
    private let waitForRecovery: Bool
    private let timeBudget: TimeInterval?
    private let checkCancellation: () throws -> Void

    init(scheduler: MailScheduler? = nil, trace: CallTrace? = nil, timeBudget: TimeInterval? = nil, waitForRecovery: Bool = false, checkCancellation: @escaping () throws -> Void = {}) {
        self.scheduler = scheduler
        self.trace = trace
        self.timeBudget = timeBudget
        self.waitForRecovery = waitForRecovery
        self.checkCancellation = checkCancellation
    }

    private func send(_ event: String, _ object: Descriptor, field: String = "-", timeout: TimeInterval = 30, extra: (Descriptor) throws -> Void = { _ in }) throws -> Descriptor {
        guard let scheduler else { return try sendDirect(event, object, field: field, timeout: timeout, extra: extra) }
        return try scheduler.send(waitForRecovery: waitForRecovery, check: checkBudget) {
            trace?.log("mail_recovery_probe")
            _ = try sendDirect("getd", property("apve", root), field: "recovery_probe", timeout: 2)
        } event: {
            try sendDirect(event, object, field: field, timeout: timeout, extra: extra)
        }
    }

    private func checkBudget() throws {
        try checkCancellation()
        if let timeBudget, let trace, trace.elapsed >= timeBudget {
            throw Failure("Mail operation reached its time budget.")
        }
    }

    private func sendDirect(_ event: String, _ object: Descriptor, field: String, timeout: TimeInterval,
                            extra: (Descriptor) throws -> Void = { _ in }) throws -> Descriptor {
        try checkCancellation()
        let remaining = min(event == "move" ? timeout : min(timeout, 4), timeBudget.map { $0 - (trace?.elapsed ?? 0) } ?? timeout)
        guard remaining >= 0.1 else {
            throw Failure("Mail did not finish within the server's time budget. Try a smaller page or narrower mailbox scope.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        func logReply(_ status: Int) {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            if status != 0 || elapsed >= 250 {
                trace?.log("apple_event=\(event) field=\(field) status=\(status) duration_ms=\(elapsed)")
            }
        }
        let request = Descriptor(eventClass: code("core"), eventID: code(event),
                                 targetDescriptor: app, returnID: -1, transactionID: 0)
        request.setParam(object, forKeyword: code("----"))
        let reply: Descriptor
        do {
            reply = try MailEventTransport.shared.perform(event: event, timeout: remaining, prepare: { try extra(request) }) { seconds in
                try request.sendEvent(options: [.waitForReply, .neverInteract], timeout: seconds)
            }
        } catch let error as MailBusy {
            throw error
        } catch let error as MailEventTimeout {
            logReply(-1712)
            throw error
        } catch let error as Failure {
            throw error
        } catch {
            let status = (error as NSError).code
            logReply(status)
            if status == -1728 { throw MailObjectNotFound() }
            if status == -1712 { throw MailEventTimeout(event: event) }
            if status == -1743 {
                throw Failure("Mail automation denied. Launch the signed app interactively once and allow access to Mail.")
            }
            throw MailReplyError(event: event, status: status)
        }
        if let error = reply.paramDescriptor(forKeyword: code("errn")), error.int32Value != 0 {
            logReply(Int(error.int32Value))
            if error.int32Value == -1728 { throw MailObjectNotFound() }
            if error.int32Value == -1712 { throw MailEventTimeout(event: event) }
            throw MailReplyError(event: event, status: Int(error.int32Value))
        }
        logReply(0)
        return reply.paramDescriptor(forKeyword: code("----")) ?? .null()
    }

    private func get(_ object: Descriptor) throws -> Descriptor { try send("getd", object) }
    private func get(_ name: String, _ object: Descriptor) throws -> Descriptor {
        do { return try send("getd", property(name, object), field: name) }
        catch { throw Failure("Reading Mail property \(name): \(error.localizedDescription)") }
    }

    private func count(_ type: String, _ object: Descriptor) throws -> Int {
        let reply = try send("cnte", object, field: type) { $0.setParam(Descriptor(typeCode: code(type)), forKeyword: code("kocl")) }
        guard reply.descriptorType == code("long"), reply.int32Value >= 0 else {
            throw Failure("Mail returned an invalid \(type) count.")
        }
        return Int(reply.int32Value)
    }

    private func objects(_ type: String, _ parent: Descriptor) throws -> [Descriptor] {
        let result: Descriptor
        do { result = try send("getd", all(type, parent), field: type) }
        catch { throw Failure("Listing Mail objects of type \(type): \(error.localizedDescription)") }
        guard result.descriptorType == code("list") else { throw Failure("Mail returned an invalid \(type) list.") }
        return (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1) }
    }

    private func childMailboxes(_ parent: Descriptor, account: String?, path: [String],
                                named requestedName: String? = nil) throws -> [Mailbox] {
        let children = try objects("mbxp", parent)
        guard !children.isEmpty else { return [] }
        let selection = all("mbxp", parent)
        func propertyValues(_ name: String) throws -> [Descriptor]? {
            let reply: Descriptor
            do {
                reply = try send("getd", property(name, selection), field: name)
            } catch is MailReplyError {
                return nil
            } catch is MailObjectNotFound {
                return nil
            }
            guard reply.descriptorType == code("list") else { return nil }
            let values = try listItems(reply)
            guard values.count == children.count else { return nil }
            return values
        }
        let names = try propertyValues("pnam")
        let containers = try requestedName == nil ? propertyValues("mbxc") : nil
        let atLocalRoot = account == nil && path.isEmpty
        let owners = try atLocalRoot ? propertyValues("mact") : nil
        if names != nil || containers != nil || owners != nil {
            guard try objects("mbxp", parent).map(\.data) == children.map(\.data) else {
                throw Failure("Mail folder hierarchy changed during lookup. Retry the request.")
            }
        }

        var seen: Set<Data> = []
        return try children.enumerated().compactMap { index, object in
            guard seen.insert(object.data).inserted else { return nil }
            if atLocalRoot, try (owners?[index] ?? get("mact", object)).descriptorType == code("obj ") { return nil }
            guard let name = try (names?[index] ?? get("pnam", object)).stringValue else {
                throw Failure("Mailbox name unavailable.")
            }
            if let requestedName, name != requestedName { return nil }

            // Account enumerations can include every descendant. Mail's container is the actual parent.
            let container = try containers?[index] ?? get("mbxc", object)
            if atLocalRoot {
                let parentType = container.forKeyword(code("want"))?.typeCodeValue
                if parentType == code("mbxp") || parentType == code("mbxc") { return nil }
            } else if container.descriptorType == code("obj ") {
                guard container.data == parent.data else { return nil }
            } else if !path.isEmpty {
                return nil
            }
            return Mailbox(account: account, path: path + [name], object: object)
        }
    }

    func catalog(accounts requested: Set<String?>? = nil) throws -> (accounts: [JSON], boxes: [Mailbox]) {
        var accounts: [JSON] = []
        var boxes: [Mailbox] = []
        func walk(_ parent: Descriptor, account: String?, path: [String]) throws {
            guard path.count < 100 else { throw Failure("Mailbox hierarchy exceeds 100 levels.") }
            for box in try childMailboxes(parent, account: account, path: path) {
                boxes.append(box)
                try walk(box.object, account: account, path: box.path)
            }
        }
        let accountObjects: [Descriptor]
        if let requested {
            accountObjects = try requested.compactMap { id in try id.map(resolveAccount) }
        } else {
            accountObjects = try objects("mact", root)
        }
        for object in accountObjects {
            guard let id = try get("ID  ", object).stringValue else { throw Failure("Account identity unavailable.") }
            guard let name = try get("pnam", object).stringValue else { throw Failure("Account identity unavailable.") }
            accounts.append(["id": id, "name": name])
            try walk(object, account: id, path: [])
        }
        if requested?.contains(nil) ?? true { try walk(root, account: nil, path: []) }
        if let requested, !requested.contains(nil), accounts.isEmpty { throw Failure("Unknown Mail account.") }
        return (accounts, boxes)
    }

    private func resolveAccount(_ account: String) throws -> Descriptor {
        if let cached = resolvedAccounts[account] { return cached }
        let reference = spec("mact", "ID  ", Descriptor(string: account), root)
        let object: Descriptor
        do {
            object = try send("getd", reference, field: "account_by_id")
        } catch is MailObjectNotFound {
            throw Failure("Mailbox account was not found.")
        }
        guard object.descriptorType == code("obj "), object.forKeyword(code("seld"))?.stringValue == account else {
            throw Failure("Mailbox account was not found.")
        }
        resolvedAccounts[account] = object
        return object
    }

    func resolve(_ address: MailboxAddress) throws -> Mailbox {
        var parent = try address.account.map(resolveAccount) ?? root
        var path: [String] = []
        for name in address.path {
            var candidates = try childMailboxes(parent, account: address.account, path: path, named: name)
            path.append(name)
            if path.count == address.path.count, let expected = address.mailboxID {
                candidates = candidates.filter { $0.id == expected }
            }
            guard candidates.count == 1, let box = candidates.first else {
                throw Failure("Path and mailboxId do not resolve to exactly one Mail mailbox.")
            }
            if path.count == address.path.count { return box }
            parent = box.object
        }
        throw Failure("Mailbox path is empty.")
    }

    func count(_ box: Mailbox) throws -> Int { try count("mssg", box.object) }

    private func range(_ box: Mailbox, offset: Int, length: Int) -> Descriptor {
        let range = Descriptor.record()
        let container = Descriptor(descriptorType: code("ccnt"), bytes: nil, length: 0)!
        range.setDescriptor(byIndex("mssg", offset + 1, container), forKeyword: code("star"))
        range.setDescriptor(byIndex("mssg", offset + length, container), forKeyword: code("stop"))
        return spec("mssg", "rang", range.coerce(toDescriptorType: code("rang"))!, box.object)
    }

    private func listItems(_ result: Descriptor) throws -> [Descriptor] {
        guard result.descriptorType == code("list") else { throw Failure("Mail returned an invalid list.") }
        return try (0..<result.numberOfItems).map { index in
            guard let item = result.atIndex(index + 1) else { throw Failure("Incomplete Mail list.") }
            return item
        }
    }

    private func columns(_ fields: [String], _ box: Mailbox, offset: Int, length: Int) throws -> [[Descriptor]] {
        let selection = range(box, offset: offset, length: length)
        var useRange = length > 50 || (scheduler?.useRange(in: box.id) ?? true)
        func column(_ field: String) throws -> [Descriptor] {
            if useRange {
                do {
                    let result = try send("getd", property(field, selection), field: field,
                                          timeout: timeBudget == nil ? 30 : 4)
                    if result.descriptorType == code("list"), result.numberOfItems == length {
                        return try listItems(result)
                    }
                } catch let error as MailEventTimeout where timeBudget != nil && length <= 50 {
                    if let scheduler {
                        scheduler.recordSlowRange(in: box.id)
                        throw error
                    }
                    trace?.log("range_timeout_fallback")
                    useRange = false
                }
            }
            return try (1...length).map { try get(field, byIndex("mssg", offset + $0, box.object)) }
        }
        let ids = try column("ID  ")
        let values = try fields.map(column)
        guard try column("ID  ").map(\.int32Value) == ids.map(\.int32Value) else {
            throw Failure("Mailbox changed during listing. Retry the page.")
        }
        return [ids] + values
    }

    private static let fields = ["meid", "subj", "sndr", "drcv", "rdrc", "msze", "isrd", "isfl"]

    private func message(_ values: [Descriptor], mailbox: Mailbox) throws -> Message {
        guard values[0].descriptorType == code("long"), values[0].int32Value > 0 else {
            throw Failure("Mail returned an invalid message ID.")
        }
        let id = Int(values[0].int32Value)
        let messageID = values[1].stringValue ?? ""
        let subject = values[2].stringValue ?? ""
        let sender = values[3].stringValue ?? ""
        let sent = values[4].dateValue
        let received = values[5].dateValue
        let json: JSON = [
            "id": id, "messageId": messageID, "mailbox": mailbox.json, "subject": subject,
            "sender": sender, "sentAt": sent.map(dateFormat.string) as Any? ?? NSNull(),
            "receivedAt": received.map(dateFormat.string) as Any? ?? NSNull(),
            "size": Int(values[6].int32Value), "read": values[7].booleanValue, "flagged": values[8].booleanValue
        ]
        return Message(id: id, messageID: messageID, subject: subject, sender: sender,
                       sent: sent, json: json)
    }

    func messages(_ box: Mailbox, offset: Int, limit: Int, total: Int) throws -> [Message] {
        let length = min(limit, max(0, total - offset))
        guard length > 0 else { return [] }
        let values = try columns(Self.fields, box, offset: offset, length: length)
        return try (0..<length).map { row in try message(values.map { $0[row] }, mailbox: box) }
    }

    func dateIndex(_ box: Mailbox, total: Int, checkCancellation: () throws -> Void) throws -> [(id: Int, date: Date)] {
        var index: [(Int, Date)] = []
        for offset in stride(from: 0, to: total, by: 500) {
            try checkCancellation()
            let length = min(500, total - offset)
            let values = try columns(["drcv", "rdrc"], box, offset: offset, length: length)
            for i in 0..<length {
                let id = Int(values[0][i].int32Value)
                guard id > 0 else { throw Failure("Mail returned an invalid message ID.") }
                index.append((id, values[1][i].dateValue ?? values[2][i].dateValue ?? .distantPast))
            }
        }
        return index
    }

    func recipients(_ id: Int, in box: Mailbox, field: String) throws -> [String] {
        let object = messageObject(id, box)
        let recipients = all(field == "to" ? "trcp" : "crcp", object)
        return try listItems(get("radd", recipients)).compactMap(\.stringValue)
    }

    private func messageObject(_ id: Int, _ box: Mailbox) -> Descriptor {
        spec("mssg", "ID  ", Descriptor(int32: Int32(id)), box.object)
    }

    func body(_ message: Message, _ box: Mailbox) throws -> String {
        let object = messageObject(message.id, box)
        guard try get("meid", object).stringValue == message.messageID else {
            throw Failure("Message changed during body search. Retry the page.")
        }
        return try get("ctnt", object).stringValue ?? ""
    }

    func prepareMove(id: Int, messageID: String, from source: Mailbox) throws {
        let object = messageObject(id, source)
        guard try get("mbxp", object).data == source.object.data,
              try get("meid", object).stringValue == messageID else {
            throw Failure("The source message no longer matches the supplied mailbox and Message-ID.")
        }
    }

    // Only an ID-based message reference under this exact destination can be
    // reconstructed later without accidentally selecting a different message.
    static func receiptID(_ reply: Descriptor, destination: Descriptor) -> Int? {
        if reply.descriptorType == code("list"), reply.numberOfItems == 1, let item = reply.atIndex(1) {
            return receiptID(item, destination: destination)
        }
        guard reply.descriptorType == code("obj "),
              reply.forKeyword(code("want"))?.typeCodeValue == code("mssg"),
              reply.forKeyword(code("form"))?.enumCodeValue == code("ID  "),
              let parent = reply.forKeyword(code("from")), parent.descriptorType == code("obj "),
              parent.data == destination.data,
              let key = reply.forKeyword(code("seld")), key.descriptorType == code("long"),
              key.int32Value > 0 else { return nil }
        return Int(key.int32Value)
    }

    func move(id: Int, to destination: Mailbox, from source: Mailbox, beforeDispatch: () throws -> Void) throws -> Int? {
        let reply = try send("move", messageObject(id, source), timeout: 8) {
            $0.setParam(destination.object, forKeyword: code("insh"))
            try beforeDispatch()
        }
        return Self.receiptID(reply, destination: destination.object)
    }

    static let reconciliationLimit = 500

    func matchingDestinationIDs(_ messageID: String, in box: Mailbox, limit: Int) throws -> [Int] {
        let count = try count(box)
        guard count <= limit else {
            throw Failure("Destination contains \(count) messages. Reconciliation is limited to \(limit).")
        }
        guard count > 0 else { return [] }
        let selection = range(box, offset: 0, length: count)
        func read(_ field: String) throws -> [Descriptor] {
            let items = try listItems(send("getd", property(field, selection), field: field, timeout: 2))
            guard items.count == count else { throw Failure("Destination changed during reconciliation.") }
            return items
        }
        let ids = try read("ID  ")
        let messageIDs = try read("meid")
        guard ids.allSatisfy({ $0.descriptorType == code("long") && $0.int32Value > 0 }),
              Set(ids.map(\.int32Value)).count == count,
              try read("ID  ").map(\.int32Value) == ids.map(\.int32Value),
              try self.count(box) == count else { throw Failure("Destination changed during reconciliation.") }
        return zip(ids, messageIDs).compactMap { $1.stringValue == messageID ? Int($0.int32Value) : nil }
    }

    func verifyMove(sourceID: Int, receiptID: Int?, baseline: [Int]?, messageID: String,
                    source: Mailbox, destination: Mailbox) throws -> MoveVerification {
        let original = messageObject(sourceID, source)
        let location: Descriptor?
        do {
            location = try send("getd", property("mbxp", original), field: "source_location")
        } catch is MailObjectNotFound {
            location = nil
        }
        if let location, location.descriptorType == code("obj "),
           location.data == destination.object.data, try get("meid", original).stringValue == messageID {
            let actualID = try get("ID  ", original)
            guard actualID.descriptorType == code("long"), actualID.int32Value > 0 else {
                throw Failure("Mail returned an invalid destination ID.")
            }
            return MoveVerification(destinationID: Int(actualID.int32Value), evidence: ["kind": "original_reference"])
        }
        if let location {
            guard location.descriptorType == code("obj "), location.data == source.object.data,
                  try get("meid", original).stringValue == messageID else {
                throw Failure("Mail returned a different object or location for the original reference.")
            }
            return MoveVerification(destinationID: nil, evidence: ["kind": "source_present", "sourceMessageAbsent": false])
        }
        // Distinguish a missing source message from a missing source mailbox.
        guard try get("pnam", source.object).stringValue == source.path.last else {
            throw Failure("The original source mailbox could not be confirmed.")
        }
        if let receiptID {
            let moved = messageObject(receiptID, destination)
            guard try get("mbxp", moved).data == destination.object.data,
                  try get("meid", moved).stringValue == messageID else {
                throw Failure("Mail has not confirmed the message identified by the move receipt.")
            }
            return MoveVerification(destinationID: receiptID, evidence: ["kind": "move_receipt", "sourceMessageAbsent": true])
        }
        return try .compare(matchingIDs: matchingDestinationIDs(messageID, in: destination, limit: Self.reconciliationLimit),
                            baseline: baseline)
    }

    func find(_ id: Int, in box: Mailbox) throws -> Message {
        let object = messageObject(id, box)
        let resolved = try get("ID  ", object)
        guard Int(resolved.int32Value) == id, try get("mbxp", object).data == box.object.data else {
            throw Failure("Message \(id) was not found in the mailbox.")
        }
        let values = try Self.fields.map { try get($0, object) }
        return try message([resolved] + values, mailbox: box)
    }

    func authorize() throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else {
            throw Failure("Mail.app was not found.")
        }
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: configuration) { _, _ in }
        let deadline = Date().addingTimeInterval(10)
        while NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let result = AEDeterminePermissionToAutomateTarget(app.aeDesc, code("core"), code("getd"), true)
        guard result == noErr else { throw Failure("Mail Automation permission check returned \(result).") }
        _ = try get("apve", root)
    }
}
