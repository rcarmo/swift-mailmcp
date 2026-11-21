# Setup

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

## Run the signed server

Generate a bearer token once and use it in your MCP client.

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

Set up the MCP client with these values.

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

| Variable | Purpose |
| --- | --- |
| `MAILMCP_TOKEN` | Override the bearer token from the owner-only token file. |
| `MAILMCP_PORT` | Override the default loopback port, 8765. |
| `MAILMCP_STATE_DIR` | Use an absolute directory for the journal and token file. The default is `~/Library/Application Support/MailMCP`. |
| `MAILMCP_TRACE_STDERR` | Set to `1` to emit request timing to stderr in a foreground run. |

[Back to the README](../README.md)
