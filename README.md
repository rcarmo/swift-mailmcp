# MailMCP

A Swift MCP server for Mail.app. It sends native Apple Events from a signed app bundle using Mail's scripting dictionary. It runs in the logged-in user's macOS session and listens on loopback.

This is a source preview. Build with Swift 5.10 or later from Xcode or the Command Line Tools. The deployment target is macOS 13. Live Mail automation has been tested on newer macOS versions on Apple silicon.

MailMCP is designed for local use. Keep the bearer token private. A client with the token can read message metadata and move messages using your Mail accounts.

## Run the signed server

[Build and sign](#build-and-sign) the app first. Generate a bearer token once and use it in your MCP client.

```sh
umask 077
config="$HOME/Library/Application Support/MailMCP"
mkdir -p "$config"
( set -C; openssl rand -hex 32 > "$config/token" )
```

Request Mail Automation access once and choose **Allow** when macOS prompts. Start the bundle through Launch Services so macOS attributes automation to MailMCP.

```sh
open -W -a "$PWD/dist/MailMCP.app" --args --authorize-mail
open -a "$PWD/dist/MailMCP.app"
```

Configure the client for **Streamable HTTP** at [http://127.0.0.1:8765/mcp](http://127.0.0.1:8765/mcp) with the header `Authorization: Bearer <token>`. At launch, `MAILMCP_TOKEN` can override the owner-only token file, and `MAILMCP_PORT` can override port 8765. The server uses request-scoped SSE for Mail reads and JSON for discovery, move acknowledgement, and move status. Clients can use MCP 2026-07-28 discovery or an initialize handshake with 2025-11-25, 2025-06-18, or 2025-03-26.

Check the connection and token from Terminal. This request lists the tool definitions without reading mail.

```sh
printf 'Authorization: Bearer %s\n' "$(cat "$HOME/Library/Application Support/MailMCP/token")" |
  curl --fail --silent --show-error --max-time 5 --header @- \
    --header 'Accept: application/json, text/event-stream' \
    --header 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    http://127.0.0.1:8765/mcp
```

## Tools and prompts

| Tool | Use |
| --- | --- |
| `list_mailboxes` | Discover account IDs, canonical nested mailbox paths, and stable `mailboxId` UUIDs. |
| `list_messages` | Page through metadata for a mailbox, an account, or all physical mailboxes. |
| `search_messages` | Search sender and subject by substring, or filter by exact `to` and `cc` addresses. Set `includeBody` for plain-text search. |
| `find_similar_messages` | Find copies and related mail by matching Message-ID, subject with common reply prefixes removed, and sender. Scores rank hits within each page. |
| `move_message` | Queue one move and return its operation ID as soon as the request is recorded. |
| `get_move_status` | Read a recorded move or request a bounded reconciliation. Expired IDs remain reserved. |

Discovery also advertises the `find_mail` and `file_mail` prompts. Use mailbox references as returned by discovery, including `accountId`, `path`, and the optional `mailboxId` check. Mailbox paths follow Mail's actual parent relationships. A real top-level folder can share a name with a nested folder and will have its own ID. Mail's scripting interface uses name-based references for most folders. Their UUIDs are derived from the account and canonical path and can change if you rename or move a folder. Use `null` for the account of an On My Mac folder.

A mailbox-scoped search defaults to newest first by sent date, falling back to received date. Use `sort: "newest"` to opt into date ordering across a wider scope, or `sort: "mailbox"` to scan in Mail's enumeration order. A request can supply `to` or `cc` without a text query. Filters match whole addresses case-insensitively and are combined with AND when both are supplied or when a query is supplied. Recipient-filtered results include `to` and `cc` arrays. Use `includeRecipients: true` to include them in text-only searches.

```json
{
  "mailbox": {"accountId": "ACCOUNT_ID", "path": ["Sent Messages"]},
  "to": "person@example.com",
  "limit": 5
}
```

Searches cover physical mailboxes Mail exposes to automation. Pass `nextOffset` as `offset` until it is null, including after an empty result page. Sync or filing can change the ordering between pages. Body search depends on content available to Mail.

## Move transactions

Pass the source, destination, local message ID, and Message-ID. The server commits a `pending` operation before replying and runs it even if the request disconnects. A caller-generated `operationId` UUID lets you repeat a submission with the same arguments and retrieve the original operation after a lost response.

Poll `get_move_status` with the operation ID. The move worker resolves both folders, checks the source mailbox and RFC Message-ID, and sends one move. A successful reply is journaled as `status: "pending"`, `phase: "awaiting_verification"`, `outcome: "accepted"`, and `safeToRetry: false`. Mail can assign a new local ID even within the same account. When the reply identifies the moved message by ID in the exact destination, a separate worker checks that object and the original source reference. A confirmed move reports `verified` and `destinationId`. An ordinary status poll reads the journal.

To request reconciliation after Mail syncs, pass `"recheck": true` to `get_move_status` for an accepted move or an unknown dispatch. The server checks whether the source reference still exists. Without a receipt or a surviving source reference, it checks for the exact RFC Message-ID in a destination of up to 500 messages. Matching IDs are recorded as observations. The move stays accepted or unknown when the evidence could come from a pre-existing copy.

For a move that needs destination evidence, submit with `"verifyArrival": true`. MailMCP records matching destination IDs before dispatch. A destination with 500 or more messages, or a failed baseline read, stops this mode before dispatch. Its background check looks for exactly one new matching ID once the original reference is gone and the baseline matches remain. Concurrent filing outside MailMCP can affect that comparison. Verification uses Mail's local view. The account provider controls remote synchronization.

A failure before dispatch reports `not_moved`. A timeout or worker interruption after dispatch with no durable reply reports `unknown` and `safeToRetry: false`. Use the existing operation ID to recheck an unknown outcome.

### Journal retention

MailMCP stores move history in `~/Library/Application Support/MailMCP/moves.sqlite3`. At startup and daily while it runs, it imports the old `moves.jsonl` journal if present and purges all events for operations whose last journal update was more than 90 days ago, including work abandoned by a stopped process. Queued or in-flight work with a live worker is preserved. A bare operation UUID remains reserved after purge. Status returns `expired` for that UUID and a submission with it cannot move mail again. Export the journal before expiry if you need a longer audit history. For an isolated instance, set `MAILMCP_STATE_DIR` to an absolute directory for its journal and token.

```sh
sqlite3 "$HOME/Library/Application Support/MailMCP/moves.sqlite3" \
  'SELECT record FROM move_events ORDER BY sequence;'
```

## Diagnose timeouts

Tool responses include an `X-MailMCP-Trace-ID` header. Watch the corresponding request, queue start, slow Apple Event, and response timing in macOS Unified Logging.

```sh
log stream --style compact --predicate 'subsystem == "net.rcarmo.mailmcp"'
```

For a foreground diagnostic run, set `MAILMCP_TRACE_STDERR=1` and redirect stderr to a local file. Use a separate `MAILMCP_PORT` if the regular server is already running.

The logs include tool names, trace IDs, operation IDs, durations, and Apple Event error codes. Read requests have a 20-second Mail budget measured from receipt, including queue time. After an Apple Event times out, the scheduler backs off and sends one lightweight readiness probe before allowing more mailbox work. For small pages, a mailbox that recently timed out on a range query uses individual indexed reads on the next call. Identical in-flight reads share one result. Mailbox discovery results are cached for five seconds. Account-scoped searches traverse only that account. Newest-first searches need dates for their full scope on a cold request. A bounded ten-second date cache serves repeated queries and pages when the mailbox count still matches. A dispatched move invalidates the source and destination caches. Use mailbox order when date ordering is optional.

Mailbox reads cap each Apple Event at four seconds. Move dispatch allows eight seconds. The preflight and dispatch share a 20-second budget, and each verification attempt has its own eight-second budget. Waiting requests check their deadlines while another event occupies the Mail connection. Once Mail has received an Apple Event, it may keep processing it after the sender times out.

## Build and sign

Use a persistent certificate-backed identity. For Developer ID, set `MAILMCP_SIGN_IDENTITY` to its name or fingerprint. For a local build without Developer ID, run `scripts/create-local-signing-identity.sh` once and use the two export lines it prints. In Keychain Access, open **MailMCP Local Code Signing** in your login keychain and set its **Code Signing** trust to **Always Trust** for that certificate. [Apple's Keychain Access guide](https://support.apple.com/en-euro/guide/keychain-access/kyca11871/mac)

```sh
export MAILMCP_SIGN_IDENTITY='<existing identity name or fingerprint>'
# For a self-signed local identity, also set MAILMCP_SIGN_CERT_SHA1 to its fingerprint.
swift test
scripts/build-app.sh
scripts/smoke-http.sh
```

The HTTP smoke test needs Python 3. It uses an isolated state directory and runs without access to Mail. Run it with a different `MAILMCP_TEST_PORT` if port 18765 is in use.

Keep the bundle identifier and signing identity stable on rebuilds. The local build pins the designated requirement to the certificate in the login keychain. Keep the private key available to sign updates. The bundle and signing scripts use Apple's [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) and [designated requirements](https://developer.apple.com/library/archive/technotes/tn2206/).

## License and credits

MailMCP is distributed under the [MIT License](LICENSE).

The Mail bridge follows the Apple Events approach used by [apple-mail-jxa-mcp](https://github.com/jakobjhartmann/apple-mail-jxa-mcp). The MCP interface follows [µMCP](https://github.com/rcarmo/umcp)'s small dispatcher, discoverable tool and prompt schemas, and separation of protocol handling from app operations.
