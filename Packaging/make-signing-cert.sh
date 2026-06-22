#!/usr/bin/env bash
# Create a self-signed CODE-SIGNING identity in your login keychain, so Pathem
# gets a STABLE signature across rebuilds. With a stable identity a Full Disk
# Access grant survives `make install` instead of breaking on every build (an
# ad-hoc signature changes each time). No Apple Developer account needed, and
# nothing leaves your Mac. The only identifying field is the Common Name below,
# generic by default, so it contains no personal info unless you pass your own.
#
#   make dev-cert                              # one-time setup
#   SIGN_IDENTITY="Pathem Self-Signed" make install
#
# (The first signed build may show one keychain prompt; click "Always Allow".)
set -euo pipefail

name="${1:-Pathem Self-Signed}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$name"; then
  echo "Code-signing identity '$name' already exists. Nothing to do."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $name
[ ext ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

# Self-signed cert with the codeSigning EKU that `codesign` requires.
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/openssl.cnf" >/dev/null 2>&1

# macOS `security import` only reads the legacy PKCS12 MAC. OpenSSL 3 needs
# -legacy to write it; LibreSSL writes it by default (and rejects -legacy), so
# fall back without the flag.
p12() { openssl pkcs12 -export "$@" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$name" -out "$tmp/identity.p12" -passout pass:pathem; }
p12 -legacy >/dev/null 2>&1 || p12 >/dev/null 2>&1

# Import the cert + private key; -A lets codesign use the key without a prompt.
security import "$tmp/identity.p12" -k "$keychain" -P pathem -A >/dev/null

# codesign refuses an untrusted identity ("no identity found"), so mark the cert
# trusted for code signing. macOS requires authorization to change trust
# settings, so this asks for your login password once. (If you prefer not to use
# the command line, Keychain Access ▸ Certificate Assistant ▸ Create a
# Certificate ▸ Code Signing does the same thing.)
echo "Trusting the certificate for code signing (you'll be asked for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"

if security find-identity -v -p codesigning | grep -qF "$name"; then
  echo "Created code-signing identity: $name"
  echo "Now build with:  SIGN_IDENTITY=\"$name\" make install"
else
  echo "Note: '$name' is imported but not showing as valid yet."
  echo "If signing fails, open Keychain Access and set the cert to 'Always Trust' for Code Signing."
fi
