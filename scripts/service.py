#!/usr/bin/env python3
"""Start the signed app via Launch Services and check MCP without reading mail."""

import argparse
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request


def read_token(directory, create=False):
    path = directory / "token"
    if create:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, "w") as output:
                output.write(secrets.token_hex(32) + "\n")
            print(f"Created bearer token at {path}; use it in your MCP client.")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Token must be a regular, owner-only file owned by this user.")
        token = source.read(514).strip("\n\r")
    if not 32 <= len(token) <= 512 or any(not 33 <= ord(c) <= 126 or c == "," for c in token):
        raise ValueError("Invalid bearer token in token file.")
    return token


def probe(url, token):
    request = urllib.request.Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"protocolVersion": "2025-11-25"}}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"},
    )
    # A local service should not use proxy settings or follow redirects with its token.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=2) as response:
        result = json.load(response)
    server = result.get("result", {}).get("serverInfo", {})
    if server.get("name") != "MailMCP":
        raise ValueError("The endpoint did not return a MailMCP initialize response.")
    print(f"MailMCP {server['version']} is healthy at {url}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("start", "status"))
    args = parser.parse_args()
    directory = Path(os.environ.get("MAILMCP_STATE_DIR", str(Path.home() / "Library/Application Support/MailMCP")))
    if not directory.is_absolute():
        raise ValueError("MAILMCP_STATE_DIR must be an absolute path.")
    port = int(os.environ.get("MAILMCP_PORT", "8765"))
    if not 1 <= port <= 65535:
        raise ValueError("MAILMCP_PORT must be between 1 and 65535.")
    if "MAILMCP_TOKEN" in os.environ:
        raise ValueError("These targets use the token file; unset MAILMCP_TOKEN first.")
    token = read_token(directory, create=args.command == "start")
    url = f"http://127.0.0.1:{port}/mcp"
    try:
        probe(url, token)
        return
    except urllib.error.URLError as error:
        # Authentication failures, sandbox denials and timeouts need diagnosis,
        # not a second process competing with the existing daemon.
        if args.command != "start" or not isinstance(error.reason, ConnectionRefusedError):
            raise

    bundle = Path(__file__).resolve().parent.parent / "dist/MailMCP.app"
    log = directory / "server.log"
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    subprocess.run([
        "/usr/bin/open", "-n", "-g", "-a", str(bundle),
        "--env", f"MAILMCP_PORT={port}", "--env", f"MAILMCP_STATE_DIR={directory}",
        "--stdout", str(log), "--stderr", str(log),
    ], check=True)
    for _ in range(50):
        try:
            probe(url, token)
            return
        except urllib.error.URLError as error:
            if not isinstance(error.reason, ConnectionRefusedError):
                raise
        time.sleep(0.1)
    raise RuntimeError(f"MailMCP did not start within 5 seconds. Check {log} or run make logs.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"MailMCP: {error}", file=sys.stderr)
        sys.exit(1)
