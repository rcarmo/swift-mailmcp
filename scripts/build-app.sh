#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

identity=${MAILMCP_SIGN_IDENTITY:?Set MAILMCP_SIGN_IDENTITY to a persistent code-signing identity}
if [[ "$identity" == "-" ]]; then
    echo "Supply a certificate-backed identity for stable signing." >&2
    exit 1
fi

config=${MAILMCP_BUILD_CONFIGURATION:-release}
mkdir -p dist .build/module-cache
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"
swift build --disable-sandbox -c "$config"
binary_dir=$(swift build --disable-sandbox -c "$config" --show-bin-path)
stage=$(mktemp -d "$PWD/dist/.build.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT

bundle="$stage/MailMCP.app"
mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$binary_dir/MailMCP" "$bundle/Contents/MacOS/MailMCP"
install -m 644 scripts/Info.plist "$bundle/Contents/Info.plist"

sign_options=(--sign "$identity" --options runtime --entitlements scripts/entitlements.plist)
if [[ -n "${MAILMCP_SIGN_KEYCHAIN:-}" ]]; then
    sign_options+=(--keychain "$MAILMCP_SIGN_KEYCHAIN")
fi
if [[ -n "${MAILMCP_SIGN_CERT_SHA1:-}" ]]; then
    fingerprint=$MAILMCP_SIGN_CERT_SHA1
    if [[ ! "$fingerprint" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "MAILMCP_SIGN_CERT_SHA1 must be the local certificate's 40-character SHA-1 fingerprint." >&2
        exit 1
    fi
    sign_options+=(--timestamp=none --requirements "=designated => identifier \"net.rcarmo.mailmcp\" and certificate leaf = H\"$fingerprint\"")
fi
codesign "${sign_options[@]}" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
codesign -d -r- "$bundle"
ditto "$bundle" "$PWD/dist/MailMCP.app"
codesign --verify --strict "$PWD/dist/MailMCP.app"
