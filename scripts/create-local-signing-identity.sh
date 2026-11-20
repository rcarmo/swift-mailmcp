#!/bin/bash
set -euo pipefail

# Provision once for a Mac without a Developer ID signing identity.
name="MailMCP Local Code Signing"
keychain=${1:-$(security default-keychain | sed -E 's/^[[:space:]]*"([^"]+)"$/\1/')}
existing=$(security find-certificate -c "$name" -Z "$keychain" 2>/dev/null || true)
if [[ -n "$existing" ]]; then
    echo "A certificate named $name already exists in $keychain. Reuse its identity." >&2
    printf '%s\n' "$existing"
    exit 1
fi

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
prompt = no
x509_extensions = extensions
[subject]
CN = MailMCP Local Code Signing
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
CONFIG
password=$(openssl rand -hex 24)
export MAILMCP_PKCS12_PASSWORD="$password"
openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 3650 \
    -config "$work/openssl.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$work/identity.p12" -passout env:MAILMCP_PKCS12_PASSWORD
security import "$work/identity.p12" -k "$keychain" -f pkcs12 -P "$password" -T /usr/bin/codesign
fingerprint=$(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
printf 'export MAILMCP_SIGN_IDENTITY=%q\nexport MAILMCP_SIGN_CERT_SHA1=%q\n' "$fingerprint" "$fingerprint"
