# Operations

## Journal retention

- The default journal is `~/Library/Application Support/MailMCP/moves.sqlite3`. Use `MAILMCP_STATE_DIR` for an isolated instance.
- At startup and daily, MailMCP imports the legacy `moves.jsonl` if present and purges operations whose last update was more than 90 days ago. A live worker's queued and in-flight moves are preserved.
- An expired operation retains only its UUID. This prevents a retry from queuing another move. Export history before the retention window closes if you need a longer record.

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

- Logs include tool names, trace IDs, operation IDs, durations, and Apple Event error codes.
- The server budgets 20 seconds for a Mail read, including queue time. Each read event can take up to four seconds. A recent range timeout can cause small pages to use indexed reads on the next call.
- Preflight and dispatch share 20 seconds per move. Dispatch allows up to eight seconds, and a background verification attempt has its own eight-second budget.
- After an event times out, the scheduler backs off and sends a lightweight readiness probe before allowing more Mail work. Mail can keep processing an event after the sender stops waiting.
- Identical in-flight reads share a result. Discovery is cached for five seconds. Account-scoped searches only traverse the specified account.
- A cold newest-first search needs dates for its full scope. The server caches dates for ten seconds when the mailbox count still matches. A dispatched move invalidates the source and destination caches. Use mailbox order when date ordering is optional.

[Back to the README](../README.md)
