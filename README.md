# MailMCP

![MailMCP app icon](docs/icon-256.png)

A macOS app that provides a local Swift MCP server for organizing messages in Apple Mail.

- **Scope.** MailMCP deliberately limits agents to organizing mail. They can discover folders, read metadata, search available content, and file messages. Sending email and accessing account credentials are outside the tool surface.
- **Local automation.** A signed app sends native Apple Events using Mail's scripting dictionary in the logged-in macOS session. The server listens on loopback for sandboxed agents. Keep the bearer token private.
- **Requirements.** This source preview builds with Swift 5.10 or later from Xcode or the Command Line Tools. The deployment target is macOS 13 to leave room for VM use. Live Mail automation has been tested on macOS 27.2.1 (26B131) on Apple silicon.

## Get started

1. [Build and sign the app](docs/setup.md#build-and-sign), then grant Mail Automation permission with `make authorize`.
2. Run `make start` to launch the app and create a token on first use. You can also [open the app in Finder and set a token](docs/setup.md#start-mailmcp).
3. In MailMCP, click **Copy Token**. Connect your MCP client to [http://127.0.0.1:8765/mcp](http://127.0.0.1:8765/mcp) using Streamable HTTP and the copied token.
4. Run `list_mailboxes` to discover the account IDs, folder paths, and mailbox IDs.

Open the status window from the Dock or choose **Show Status** from the menu
bar envelope. The window shows the endpoint and masks the current token. Run
`make status` to check the authenticated endpoint from Terminal.

## Tools and prompts

| Tool | Use |
| --- | --- |
| `list_mailboxes` | Discover account IDs, canonical nested mailbox paths, and stable `mailboxId` UUIDs. |
| `list_messages` | Page through metadata for a mailbox, an account, or all physical mailboxes. |
| `search_messages` | Search sender and subject by substring, or filter by exact `to` and `cc` addresses. Set `includeBody` for plain-text search. |
| `find_similar_messages` | Find copies and related mail by matching Message-ID, subject with common reply prefixes removed, and sender. Scores rank hits within each page. |
| `move_message` | Queue one move and return its operation ID as soon as the request is recorded. |
| `move_messages` | Queue up to 50 moves in one call, with individual operation IDs and outcomes. |
| `get_move_status` | Read a recorded move or request a bounded reconciliation. Expired IDs remain reserved. |

The `find_mail` and `file_mail` prompts guide clients through search and filing.

### Search and listing

- Use the account, full nested path, and optional `mailboxId` returned by `list_mailboxes`. Use `null` for the account of an On My Mac folder. Same-name folders can coexist at different paths. A path-derived ID can change if its folder is renamed or moved.
- Mailbox-scoped searches default to newest first by sent date, with received date as a fallback. Account-wide searches default to Mail's enumeration order. Set `sort` explicitly to choose either order.
- Pass an exact `to` or `cc` address with or without a text query. All supplied filters must match. Recipient filters include both recipient arrays in the result. Set `includeRecipients` for text-only queries that also need addresses.
- Follow `nextOffset` until it is null, including after a page with no matches. Mail sync and filing can shift page boundaries. Searches cover physical mailboxes and the content Mail exposes.

Example search arguments.

```json
{
  "mailbox": {"accountId": "ACCOUNT_ID", "path": ["Sent Messages"]},
  "to": "person@example.com",
  "limit": 5
}
```

## Filing and operations

- [Single and batch moves](docs/moves.md) covers request examples, acknowledgement, status, and verification.
- [Operations](docs/operations.md) covers the 90-day journal retention policy, diagnostics, and timeouts.

## License and credits

MailMCP is distributed under the [MIT License](LICENSE).

The Mail bridge follows the Apple Events approach used by [apple-mail-jxa-mcp](https://github.com/jakobjhartmann/apple-mail-jxa-mcp). The MCP interface follows [µMCP](https://github.com/rcarmo/umcp)'s small dispatcher, discoverable tool and prompt schemas, and separation of protocol handling from app operations.
