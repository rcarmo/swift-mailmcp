# Setup

## Build and sign

Use a persistent certificate-backed identity. For Developer ID, set `MAILMCP_SIGN_IDENTITY` to its name or fingerprint. For a local build without Developer ID, run `scripts/create-local-signing-identity.sh` once and use the two export lines it prints. In Keychain Access, open **MailMCP Local Code Signing** in your login keychain and set its **Code Signing** trust to **Always Trust** for that certificate. [Apple's Keychain Access guide](https://support.apple.com/en-euro/guide/keychain-access/kyca11871/mac)

```sh
export MAILMCP_SIGN_IDENTITY='<existing identity name or fingerprint>'
# For a self-signed local identity, also set MAILMCP_SIGN_CERT_SHA1 to its fingerprint.
make build
```

Keep the bundle identifier and signing identity stable on rebuilds. The local build pins the designated requirement to the certificate in the login keychain. Keep the private key available to sign updates. The bundle and signing scripts use Apple's [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) and [designated requirements](https://developer.apple.com/library/archive/technotes/tn2206/).

## Grant Mail Automation access

Run `make authorize` and choose **Allow** when macOS asks to let MailMCP control
Mail. The command opens the signed bundle so macOS can attribute that permission
to MailMCP.

## Start MailMCP

Open `dist/MailMCP.app` from Finder. If the app has no token yet, generate one
with `openssl rand -hex 32`, paste it into the **Bearer token** field, and click
**Set Token** to start the server.

With Python 3 installed, you can also launch and check the app from Terminal.

```sh
make start
make status
```

`make start` creates an owner-only token file if needed, builds the signed
bundle if it is missing, and reuses an already healthy instance. Run
`make build` explicitly after source changes. `make status` checks the
authenticated endpoint without accessing Mail. See [Operations](operations.md#check-the-running-app)
for startup troubleshooting.

Click the Dock icon or choose **Show Status** from the menu bar envelope to
open the status window. Closing the window keeps the server running. Choose
**Quit MailMCP** to stop the server.

## Connect your MCP client

Click **Copy Token** in the status window and configure the client.

- **Transport** is Streamable HTTP.
- **Endpoint** is [http://127.0.0.1:8765/mcp](http://127.0.0.1:8765/mcp).
- **Header** is `Authorization: Bearer <token>`.
- **Protocol** supports MCP 2026-07-28 discovery and the initialize handshakes for 2025-11-25, 2025-06-18, and 2025-03-26. Mail reads use request-scoped SSE. Discovery, move acknowledgements, and move status use JSON.

Check the connection and token from Terminal. This request lists the tool definitions without reading mail.

```sh
printf 'Authorization: Bearer %s\n' "$(cat "$HOME/Library/Application Support/MailMCP/token")" |
  curl --fail --silent --show-error --max-time 5 --header @- \
    --header 'Accept: application/json, text/event-stream' \
    --header 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    http://127.0.0.1:8765/mcp
```

## Runtime settings

The **Bearer token** field shows the active token as dots. Edit it and click
**Set Token** to save a replacement and apply it immediately. Update your MCP
clients with the new value. Tokens must be 32 to 512 printable ASCII
characters, without spaces or commas. A token supplied by `MAILMCP_TOKEN`
can be copied from the app and is changed through the environment.

| Variable | Purpose |
| --- | --- |
| `MAILMCP_TOKEN` | Override the bearer token from the owner-only token file. |
| `MAILMCP_PORT` | Override the default loopback port, 8765. |
| `MAILMCP_STATE_DIR` | Use an absolute directory for the journal and token file. The default is `~/Library/Application Support/MailMCP`. |
| `MAILMCP_TRACE_STDERR` | Set to `1` to emit request timing to stderr in a foreground run. |

`make start` and `make status` honor `MAILMCP_PORT` and `MAILMCP_STATE_DIR` and
use the token file. Unset `MAILMCP_TOKEN` when using those targets.

## Test a build

Run `make test` for Swift tests and `make smoke` for HTTP checks. The smoke
check needs Python 3 and runs the server in an isolated state directory without
accessing Mail. Set `MAILMCP_TEST_PORT` if port 18765 is in use. `make help`
lists the available targets.

[Back to the README](../README.md)
