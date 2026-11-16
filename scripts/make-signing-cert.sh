#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity "aeropeek Dev" in the login keychain.
# WHY: an ad-hoc build gets a new code identity on every build, so macOS drops its Accessibility and
# Screen Recording grants after each rebuild. A real (even self-signed) certificate gives an identity
# those grants stick to.
# Adapted from Boopr's scripts/make-signing-cert.sh (memorte03/boopr-claude-notifier),
# MIT License, Copyright (c) 2026 memorte03.
# Run once. macOS may ask for your login password to trust the certificate.
set -euo pipefail

CERT_NAME="aeropeek Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# grep reads to the end (no -q): under pipefail an early exit would fail the pipeline through SIGPIPE.
has_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$CERT_NAME\"" >/dev/null; }

if has_identity; then
  echo "identity '$CERT_NAME' already exists"
  exit 0
fi
# A certificate that exists without being a valid identity was imported but never trusted.
# Generating another would leave two with the same name.
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "certificate '$CERT_NAME' exists but is not trusted for code signing: Keychain Access → login → '$CERT_NAME' → Trust → Code Signing → Always Trust" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# The system's own openssl, so the result does not depend on what else is installed.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" 2>/dev/null

# Separate PEMs, not PKCS12: OpenSSL 3 p12 files fail `security import` MAC verification.
security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
  echo "trust not set automatically: Keychain Access → login → '$CERT_NAME' → Trust → Code Signing → Always Trust" >&2
fi

if has_identity; then
  echo "created code-signing identity '$CERT_NAME'"
else
  echo "identity not valid yet (trust step incomplete?)" >&2
  exit 1
fi
