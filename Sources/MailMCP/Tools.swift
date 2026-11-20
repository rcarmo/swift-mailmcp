import Foundation
import CoreFoundation

struct Arguments {
    let values: JSON

    func string(_ key: String, required: Bool = false) throws -> String? {
        if values[key] == nil && !required { return nil }
        guard let value = values[key] as? String, !value.isEmpty else {
            throw Failure("\(key) must be a nonempty string.")
        }
        return value
    }

    func integer(_ key: String, default fallback: Int? = nil, in range: ClosedRange<Int>) throws -> Int {
        if values[key] == nil, let fallback { return fallback }
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              let integer = Int(exactly: value.doubleValue), range.contains(integer) else {
            throw Failure("\(key) must be an integer between \(range.lowerBound) and \(range.upperBound).")
        }
        return integer
    }

    func boolean(_ key: String) throws -> Bool {
        guard let value = values[key] else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw Failure("\(key) must be a boolean.")
        }
        return number.boolValue
    }

    func mailboxAddress(_ key: String) throws -> MailboxAddress {
        guard let spec = values[key] as? JSON, let path = spec["path"] as? [String],
              !path.isEmpty, path.allSatisfy({ !$0.isEmpty }),
              spec["accountId"] is NSNull || spec["accountId"] is String else {
            throw Failure("\(key) requires a path array and an accountId. Use null for On My Mac.")
        }
        var mailboxID: UUID?
        if let rawID = spec["mailboxId"] {
            guard let text = rawID as? String, let uuid = UUID(uuidString: text) else {
                throw Failure("\(key).mailboxId must be a UUID.")
            }
            mailboxID = uuid
        }
        return MailboxAddress(account: spec["accountId"] as? String, path: path, mailboxID: mailboxID)
    }

    func operationID(required: Bool) throws -> UUID? {
        guard let value = try string("operationId", required: required) else { return nil }
        guard let id = UUID(uuidString: value) else { throw Failure("operationId must be a UUID.") }
        return id
    }

}

final class Tools {
    private let moves: MoveOperations
    private let scheduler: MailScheduler
    private let reads = MailReads()

    func startMaintenance() { moves.startMaintenance() }

    init(stateDirectory: URL) {
        let scheduler = MailScheduler()
        self.scheduler = scheduler
        moves = MoveOperations(automation: DispatchQueue(label: "MailMCP.MoveWorker"), directory: stateDirectory) { record in
            let args = Arguments(values: record)
            let trace = try CallTrace("move_verification", id: args.operationID(required: true)!)
            let mail = Mail(scheduler: scheduler, trace: trace, timeBudget: 8)
            return try mail.verifyMove(sourceID: args.integer("id", in: 1...Int(Int32.max)),
                                       receiptID: record["receiptId"] as? Int,
                                       baseline: record["destinationBaselineIds"] as? [Int],
                                       messageID: args.string("messageId", required: true)!,
                                       source: mail.resolve(args.mailboxAddress(record["resolvedSource"] == nil ? "source" : "resolvedSource")),
                                       destination: mail.resolve(args.mailboxAddress(record["resolvedDestination"] == nil ? "destination" : "resolvedDestination")))
        }
    }

    func takeOverMoves(_ ids: [UUID]) throws {
        try moves.takeOver(ids) { record, progress in
            let args = Arguments(values: record)
            return try self.executeMove(source: args.mailboxAddress("source"), destination: args.mailboxAddress("destination"),
                                        id: args.integer("id", in: 1...Int(Int32.max)),
                                        messageID: args.string("messageId", required: true)!,
                                        verifyArrival: args.boolean("verifyArrival"),
                                        trace: CallTrace("move_worker", id: args.operationID(required: true)!), progress: progress)
        }
    }

    static func usesMailQueue(_ name: String) -> Bool {
        name != "move_message" && name != "get_move_status"
    }
    private static let string: JSON = ["type": "string", "minLength": 1]
    private static let uuid: JSON = ["type": "string", "format": "uuid"]
    private static let index: JSON = [
        "type": "integer", "minimum": 0,
        "description": "Use nextOffset from the previous response with the same filter, scope, and sort."
    ]
    private static let id: JSON = ["type": "integer", "minimum": 1, "maximum": Int32.max]
    private static let limit: JSON = [
        "type": "integer", "minimum": 1, "maximum": 100, "default": 25,
        "description": "Maximum number of results to return."
    ]
    private static let account: JSON = [
        "type": ["string", "null"],
        "description": "An account ID from list_mailboxes. Use null to scope to On My Mac."
    ]
    private static let mailbox: JSON = [
        "type": "object", "required": ["accountId", "path"], "additionalProperties": false,
        "properties": [
            "accountId": account,
            "path": ["type": "array", "minItems": 1, "items": string,
                     "description": "The exact ordered folder names from list_mailboxes, starting at the account root."],
            "mailboxId": described(uuid, "Pass the ID from the same listed folder to verify its identity.")
        ]
    ]
    private static let scope: JSON = [
        "accountId": account,
        "mailbox": described(mailbox, "Scope to an exact physical mailbox. Supply mailbox or accountId, or omit both to use all accounts."),
        "offset": index, "limit": limit
    ]
    private static let scanLimit: JSON = [
        "type": "integer", "minimum": 1, "maximum": 2000,
        "description": "Maximum candidate messages to check in this call. This can exceed the result limit."
    ]

    private static func described(_ schema: JSON, _ text: String) -> JSON {
        schema.merging(["description": text]) { _, new in new }
    }

    private static func tool(_ name: String, title: String, _ description: String, _ properties: JSON = [:],
                             required: [String] = [], requiresOneOf: [String] = [], writes: Bool = false) -> JSON {
        var schema: JSON = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        if !requiresOneOf.isEmpty {
            schema["anyOf"] = requiresOneOf.map { ["required": [$0]] }
        }
        return [
            "name": name, "title": title, "description": description, "inputSchema": schema,
            "annotations": ["readOnlyHint": !writes, "destructiveHint": writes, "openWorldHint": writes]
        ]
    }

    static let definitions: [JSON] = [
        tool("list_mailboxes", title: "Discover Mail accounts and folders",
             """
             Get account names and IDs plus the canonical paths and mailbox IDs of physical folders. Use the returned mailbox object as-is when listing, searching, or moving. A shared folder name can refer to different folders. Confirm the account and full path before using it as a destination.
             """),
        tool("list_messages", title: "List Mail message metadata",
             """
             Browse messages in Mail's enumeration order. Each result includes the mailbox, local ID, Message-ID, sender, subject, dates, size, and read and flag state. Use search_messages for recipient filters or newest-first results. Pass nextOffset back to continue browsing.
             """, scope),
        tool("search_messages", title: "Search Mail by text or recipient",
             """
             Find messages by text, To address, Cc address, or a combination. Use to or cc to verify a recipient. These filters match whole email addresses and include the To and Cc arrays in the response. Scope sent-mail searches to the intended account's Sent folder. Mailbox-scoped searches default to newest first. Follow nextOffset even on an empty page. A null nextOffset ends the search.
             """, scope.merging([
                "query": described(string, "Case- and accent-insensitive substring in sender or subject. Also checks the plain-text body when includeBody is true."),
                "includeBody": ["type": "boolean", "default": false,
                                "description": "Expand text matching to the plain-text body available to Mail."],
                "includeRecipients": ["type": "boolean", "default": false,
                                      "description": "Return To and Cc email addresses on text-only searches. Recipient filters include them automatically."],
                "to": described(string, "Exact To email address with case ignored. Can be used without query."),
                "cc": described(string, "Exact Cc email address with case ignored. Can be used without query."),
                "sort": ["type": "string", "enum": ["newest", "mailbox"],
                         "description": "Newest uses sent date, falling back to received date. Mailbox uses Mail's enumeration order and is the default for account-wide and all-account searches."],
                "scanLimit": scanLimit
             ]) { _, new in new }, requiresOneOf: ["query", "to", "cc"]),
        tool("find_similar_messages", title: "Find copies and related mail",
             """
             Compare messages to a known message in Mail. An exact Message-ID match scores 100. Otherwise a normalized subject match scores 60 and a matching sender address adds 25. Results exclude the reference and are ranked within each page. Use search_messages for address or body matching.
             """, scope.merging([
                "referenceMailbox": described(mailbox, "The reference message's mailbox, as returned by listing or search."),
                "referenceId": described(id, "The reference message's local numeric id."),
                "scanLimit": scanLimit
             ]) { _, new in new }, required: ["referenceMailbox", "referenceId"]),
        tool("move_message", title: "Queue a Mail move",
             """
             Queue a move between two exact physical mailboxes. Use the id and messageId from the same source listing or search result. The response acknowledges a recorded operation. Poll get_move_status to learn whether Mail confirmed the move. If the response is lost, resubmit with the same operationId and identical arguments to retrieve the original operation.
             """, [
                "source": described(mailbox, "The message's current mailbox from listing or search."),
                "destination": described(mailbox, "The intended folder from list_mailboxes. This may be in another account."),
                "id": described(id, "The local numeric id from the source message."),
                "messageId": described(string, "The exact RFC Message-ID returned as messageId for the same source message."),
                "operationId": described(uuid, "Generate this UUID before submitting if you need to recover from a lost acknowledgement."),
                "verifyArrival": ["type": "boolean", "default": false, "description": "Record a destination baseline before dispatch so a new destination ID can verify the move when Mail returns no receipt. Requires a destination with fewer than \(Mail.reconciliationLimit) messages."]
             ], required: ["source", "destination", "id", "messageId"], writes: true),
        tool("get_move_status", title: "Check a Mail move",
             """
             Read the journal by operation ID. Queued, preflight and applying are in progress. Phase awaiting_verification with outcome accepted means Mail acknowledged the move. A usable receipt or destination baseline triggers one background check. Set recheck on an accepted or unknown move to request bounded reconciliation after sync. Observed matching destination IDs can include pre-existing copies. Only verified includes a confirmed destinationId. Expired means the audit details were purged and the UUID remains reserved.
             """, ["operationId": described(uuid, "The UUID supplied to or returned by move_message."),
                   "recheck": ["type": "boolean", "default": false, "description": "Request read-only background reconciliation of an accepted or unknown move."]], required: ["operationId"])
    ]

    func call(_ name: String, values: JSON, trace: CallTrace, checkCancellation: @escaping () throws -> Void) throws -> JSON {
        guard let definition = Self.definitions.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? JSON, let properties = schema["properties"] as? JSON else {
            throw Failure("Unknown Mail tool.")
        }
        guard Set(values.keys).isSubset(of: properties.keys) else { throw Failure("Unknown tool argument.") }
        let args = Arguments(values: values)
        switch name {
        case "move_message":
            return try submitMove(args, checkCancellation: checkCancellation)
        case "get_move_status":
            return try moves.status(args.operationID(required: true)!, recheck: args.boolean("recheck"))
        default:
            break
        }
        let key = try JSONSerialization.data(withJSONObject: ["tool": name, "arguments": values], options: [.sortedKeys])
        return try reads.run(key, cacheDiscovery: name == "list_mailboxes", check: {
            try checkCancellation()
            guard trace.elapsed < 20 else { throw Failure("Mail read reached its 20-second time budget.") }
        }) { check in
            let mail = Mail(scheduler: scheduler, trace: trace, timeBudget: 20, checkCancellation: check)
            switch name {
            case "list_mailboxes":
                let catalog = try mail.catalog()
                return ["accounts": catalog.accounts, "mailboxes": catalog.boxes.map(\.json)]
            case "list_messages", "find_similar_messages":
                return try scan(name, args: args, mail: mail, checkCancellation: check)
            case "search_messages":
                return try search(args, mail: mail, checkCancellation: check)
            default:
                throw Failure("Unknown Mail tool.")
            }
        }
    }

    private func mailboxes(_ args: Arguments, mail: Mail) throws -> [Mailbox] {
        if args.values["mailbox"] != nil {
            guard args.values["accountId"] == nil else { throw Failure("Supply either mailbox or accountId.") }
            return [try mail.resolve(args.mailboxAddress("mailbox"))]
        }
        guard args.values["accountId"] != nil else { return try mail.catalog().boxes }
        let account = args.values["accountId"] is NSNull ? nil : try args.string("accountId", required: true)
        return try mail.catalog(accounts: [account]).boxes
    }

    private func search(_ args: Arguments, mail: Mail, checkCancellation: () throws -> Void) throws -> JSON {
        let query = try args.string("query")
        let filters = try ["to", "cc"].compactMap { field in
            try args.string(field).map { (field, $0) }
        }
        guard query != nil || !filters.isEmpty else { throw Failure("Supply at least one of query, to, or cc.") }
        let includeBody = try args.boolean("includeBody")
        let includeRecipients = try args.boolean("includeRecipients") || !filters.isEmpty
        let sort = try args.string("sort") ?? (args.values["mailbox"] != nil ? "newest" : "mailbox")
        guard sort == "newest" || sort == "mailbox" else { throw Failure("sort must be newest or mailbox.") }
        let offset = try args.integer("offset", default: 0, in: 0...Int.max)
        let limit = try args.integer("limit", default: 25, in: 1...100)
        let scanLimit = try args.integer("scanLimit", default: includeBody ? 50 : 500, in: 1...2000)
        let boxes = try mailboxes(args, mail: mail)
        var results: [JSON] = []
        var scanned = 0

        func evaluate(_ id: Int, in box: Mailbox, loadMessage: () throws -> Message) throws {
            try checkCancellation()
            scanned += 1
            var recipientFields: [String: [String]] = [:]
            for (field, value) in filters {
                let addresses = try mail.recipients(id, in: box, field: field)
                guard addresses.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
                recipientFields[field] = addresses
            }
            let message = try loadMessage()
            if let query, ![message.subject, message.sender].contains(where: { $0.localizedStandardContains(query) }) {
                guard includeBody, try mail.body(message, box).localizedStandardContains(query) else { return }
            }
            var result = message.json
            if includeRecipients {
                for field in ["to", "cc"] {
                    result[field] = try recipientFields[field] ?? mail.recipients(id, in: box, field: field)
                }
            }
            results.append(result)
        }

        var hasMore = false
        if sort == "newest" {
            var candidates: [(box: Mailbox, id: Int, date: Date)] = []
            for box in boxes {
                try checkCancellation()
                let count = try mail.count(box)
                let dates = try reads.dates(in: box.id, count: count) {
                    try mail.dateIndex(box, total: count, checkCancellation: checkCancellation)
                }
                candidates += dates.map { (box, $0.id, $0.date) }
            }
            candidates.sort { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
            for candidate in candidates.dropFirst(offset).prefix(scanLimit) {
                try evaluate(candidate.id, in: candidate.box) { try mail.find(candidate.id, in: candidate.box) }
                if results.count == limit { break }
            }
            hasMore = offset < candidates.count && scanned < candidates.count - offset
        } else {
            hasMore = try visitMessages(boxes, mail: mail, offset: offset, scanLimit: scanLimit, batchSize: 50,
                                        checkCancellation: checkCancellation) { message, box in
                try evaluate(message.id, in: box) { message }
                return results.count == limit
            }
        }
        return ["messages": results, "scanned": scanned, "nextOffset": hasMore ? (offset + scanned) as Any : NSNull()]
    }

    private func scan(_ name: String, args: Arguments, mail: Mail, checkCancellation: () throws -> Void) throws -> JSON {
        let boxes = try mailboxes(args, mail: mail)
        let offset = try args.integer("offset", default: 0, in: 0...Int.max)
        let limit = try args.integer("limit", default: 25, in: 1...100)
        let scanLimit = try args.integer("scanLimit", default: name == "list_messages" ? limit : 500, in: 1...2000)
        let referenceBox = try name == "find_similar_messages" ? mail.resolve(args.mailboxAddress("referenceMailbox")) : nil
        let reference = try referenceBox.map { try mail.find(args.integer("referenceId", in: 1...Int(Int32.max)), in: $0) }
        var scored: [(Message, Int)] = []
        var scanned = 0
        let hasMore = try visitMessages(boxes, mail: mail, offset: offset, scanLimit: scanLimit,
                                        batchSize: reference == nil ? limit : 50, checkCancellation: checkCancellation) { message, box in
            scanned += 1
            if let reference, let referenceBox {
                let isReference = message.id == reference.id && box.path == referenceBox.path && box.account == referenceBox.account
                if !isReference {
                    let score = similarity(message, reference)
                    if score > 0 { scored.append((message, score)) }
                }
            } else {
                scored.append((message, 1))
            }
            return scored.count == limit
        }

        let messages = scored.sorted { $0.1 > $1.1 }.map { message, score in
            reference == nil ? message.json : message.json.merging(["similarityScore": score]) { value, _ in value }
        }
        return ["messages": messages, "scanned": scanned, "nextOffset": hasMore ? (offset + scanned) as Any : NSNull()]
    }

    private func visitMessages(_ boxes: [Mailbox], mail: Mail, offset: Int, scanLimit: Int, batchSize: Int,
                               checkCancellation: () throws -> Void, visit: (Message, Mailbox) throws -> Bool) throws -> Bool {
        var scanned = 0
        var skip = offset
        for (boxIndex, box) in boxes.enumerated() {
            try checkCancellation()
            let count = try mail.count(box)
            if skip >= count {
                skip -= count
                continue
            }
            var position = skip
            skip = 0
            while position < count {
                try checkCancellation()
                let length = min(batchSize, count - position, scanLimit - scanned)
                let batch = try mail.messages(box, offset: position, limit: length, total: count)
                for (index, message) in batch.enumerated() {
                    scanned += 1
                    if try visit(message, box) || scanned == scanLimit {
                        return position + index + 1 < count || boxIndex + 1 < boxes.count
                    }
                }
                position += length
            }
        }
        return false
    }

    private func similarity(_ candidate: Message, _ reference: Message) -> Int {
        if !reference.messageID.isEmpty && reference.messageID == candidate.messageID { return 100 }
        func normalizedSubject(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: #"^\s*(?:(?:re|fw|fwd)\s*:\s*)+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func address(_ value: String) -> String {
            if let start = value.lastIndex(of: "<"), value.hasSuffix(">") {
                return String(value[value.index(after: start)..<value.index(before: value.endIndex)]).lowercased()
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        let subject = normalizedSubject(reference.subject)
        let sender = address(reference.sender)
        var score = 0
        if !subject.isEmpty && normalizedSubject(candidate.subject) == subject { score += 60 }
        if !sender.isEmpty && address(candidate.sender) == sender { score += 25 }
        return score
    }

    private func submitMove(_ args: Arguments, checkCancellation: () throws -> Void) throws -> JSON {
        let source = try args.mailboxAddress("source")
        let destination = try args.mailboxAddress("destination")
        guard source != destination else { throw Failure("Source and destination must differ.") }
        let id = try args.integer("id", in: 1...Int(Int32.max))
        let key = try args.string("messageId", required: true)!
        let verifyArrival = try args.boolean("verifyArrival")
        let operationID = try args.operationID(required: false) ?? UUID()
        try checkCancellation()
        return try moves.submit(operationID, source: source, destination: destination, id: id, messageID: key,
                                verifyArrival: verifyArrival) { progress in
            try self.executeMove(source: source, destination: destination, id: id, messageID: key,
                                 verifyArrival: verifyArrival, trace: CallTrace("move_worker", id: operationID),
                                 progress: progress)
        }
    }

    private func executeMove(source: MailboxAddress, destination: MailboxAddress, id: Int, messageID: String,
                             verifyArrival: Bool, trace: CallTrace, progress: MoveProgress) throws -> JSON {
        let mail = Mail(scheduler: scheduler, trace: trace, timeBudget: 20, waitForRecovery: true)
        let source = try mail.resolve(source)
        let destination = try mail.resolve(destination)
        guard source.id != destination.id else { throw Failure("Source and destination resolve to the same mailbox.") }
        var evidence: JSON = ["resolvedSource": source.json, "resolvedDestination": destination.json]
        if verifyArrival {
            evidence["destinationBaselineIds"] = try mail.matchingDestinationIDs(
                messageID, in: destination, limit: Mail.reconciliationLimit - 1)
        }
        try mail.prepareMove(id: id, messageID: messageID, from: source)
        defer { reads.invalidateDates([source.id, destination.id]) }
        let receipt = try mail.move(id: id, to: destination, from: source) {
            try progress(.applying, evidence)
        }
        var accepted: JSON = ["status": "pending", "outcome": "accepted", "safeToRetry": false]
        if let receipt { accepted["receiptId"] = receipt }
        trace.log(receipt == nil ? "accepted_without_receipt_id" : "accepted_with_receipt_id")
        return accepted
    }
}
