# Moving messages

## Submit moves

- Use `move_message` for one message or `move_messages` for 1–50 messages. Each entry specifies its own source and destination, which can be in different accounts.
- For each message, use the `id`, `messageId`, and source mailbox from the same listing or search result. Use the destination object returned by `list_mailboxes`.
- Supply a unique `operationId` UUID for each batch entry. It is optional for `move_message`. Save the UUIDs and resubmit identical arguments with those UUIDs if the acknowledgement is lost.
- MailMCP records all new batch entries in one SQLite transaction and returns `operations` in input order. A conflicting operation ID or insufficient queue capacity rejects all new entries in that call. The worker can hold up to 64 undispatched or executing moves across submissions.
- The worker reuses recent mailbox resolutions within a batch and sends a targeted Apple Event per message. Mail can complete some entries even if others fail. A disconnected client leaves recorded moves queued.

Example arguments for `move_messages`.

```json
{
  "moves": [
    {
      "operationId": "957ced88-102c-4e86-87b2-fd4c7733de95",
      "source": {"accountId": "SOURCE_ACCOUNT", "path": ["Inbox"]},
      "destination": {"accountId": "DESTINATION_ACCOUNT", "path": ["Shopping", "Receipts"]},
      "id": 42,
      "messageId": "receipt-42@example.com"
    },
    {
      "operationId": "3a23f5a0-cf5f-464c-9eba-ae3bc72f02f3",
      "source": {"accountId": "SOURCE_ACCOUNT", "path": ["Inbox"]},
      "destination": {"accountId": "DESTINATION_ACCOUNT", "path": ["Shopping", "Receipts"]},
      "id": 43,
      "messageId": "receipt-43@example.com"
    }
  ]
}
```

## Check each result

Use `get_move_status` with an operation ID. Ordinary polling reads the journal.

| State | Meaning |
| --- | --- |
| `queued`, `preflight`, or `applying` | The operation is in progress. |
| `awaiting_verification` with outcome `accepted` | Mail acknowledged the move. Verification is still pending. |
| `verified` | MailMCP confirmed the destination and recorded `destinationId`. Mail can assign a new local ID even within the same account. |
| `failed` with outcome `not_moved` | The worker stopped before dispatch. |
| `failed` with outcome `unknown` | Dispatch may have succeeded. Recheck the same ID before any new filing attempt. |
| `expired` | The journal details were purged and the UUID remains reserved. |

### Verification

- A usable destination receipt triggers a separate background check of the destination and the original source reference.
- Set `"recheck": true` to request reconciliation for an accepted or unknown move. Without a receipt or a surviving source reference, MailMCP looks for the exact RFC Message-ID in a destination of up to 500 messages. These are observations because a match can be a pre-existing copy.
- Set `"verifyArrival": true` on a move to record matching destination IDs before dispatch. A destination with 500 or more messages or an unsuccessful baseline read stops that move before dispatch. The background check looks for one new matching ID after the original reference disappears.
- A batch using `verifyArrival` requires distinct RFC Message-IDs for the entries going to that destination. Concurrent filing outside MailMCP can affect the baseline comparison. Verification uses Mail's local view of the account.

[Journal retention and diagnostics](operations.md) · [Back to the README](../README.md)
