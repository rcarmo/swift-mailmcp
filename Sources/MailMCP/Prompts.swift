import Foundation

enum Prompts {
    private struct Prompt {
        let name: String
        let title: String
        let description: String
        let argument: String
        let argumentDescription: String
        let instructions: String

        var definition: JSON {
            ["name": name, "title": title, "description": description,
             "arguments": [["name": argument, "description": argumentDescription, "required": true]]]
        }
    }

    private static let prompts = [
        Prompt(name: "find_mail", title: "Find and verify messages",
               description: "Find mail by text or recipient and report what Mail returned.",
               argument: "query", argumentDescription: "Describe the messages to find, including any recipient, account, or folder you know.",
               instructions: """
               1. Use list_mailboxes when the request names an account or folder. Use the returned accountId, path, and mailboxId. For sent mail, scope to the intended account's Sent folder.
               2. Use search_messages with an exact to or cc address when you know it. Use query for sender or subject text and includeBody only when body text matters. To identify an unknown recipient, request includeRecipients and check the returned addresses.
               3. For the latest match, use newest ordering and continue through empty pages while nextOffset is present. Use find_similar_messages when a specific message is the reference for copies or related mail.
               4. Report the matching subject, relevant date, mailbox, and any address you verified. If you stop before reaching the end of the search, say how much you checked.
               """),
        Prompt(name: "file_mail", title: "File messages and verify each move",
               description: "Identify the intended mail and destination, then report the recorded filing outcome and supporting evidence.",
               argument: "request", argumentDescription: "Describe the messages to file and where they belong.",
               instructions: """
               1. Find the intended messages and resolve the destination with list_mailboxes. Use each message's returned source mailbox and the destination's full account, path, and mailboxId. If more than one source selection or destination fits the request, ask which one the user means.
               2. Submit one move_message call per selected message using its id and messageId. Use verifyArrival when the user needs verified filing and the destination has fewer than \(Mail.reconciliationLimit) messages. Generate a separate operationId UUID per message. If the acknowledgement is lost, send identical arguments and the same UUID.
               3. Poll get_move_status while queued, in preflight, or applying. For an accepted move or an unknown outcome, wait for any background check, then request one recheck after sync if needed. An accepted or unknown move must never be resubmitted just to verify it.
               4. Report verified moves with their destination and operation ID. For an unresolved move, report any observed destination matches and whether the original source reference remains. A matching RFC Message-ID may belong to a pre-existing copy.
               """)
    ]

    static var definitions: [JSON] { prompts.map(\.definition) }

    static func get(_ name: String, arguments: JSON) throws -> JSON {
        guard let prompt = prompts.first(where: { $0.name == name }) else { throw Failure("Unknown prompt.") }
        guard arguments.count == 1, let input = try Arguments(values: arguments).string(prompt.argument, required: true) else {
            throw Failure("Expected argument \(prompt.argument).")
        }
        return ["description": prompt.description,
                "messages": [["role": "user", "content": ["type": "text", "text": "\(prompt.instructions)\n\nRequest\n\(input)"]]]]
    }
}
