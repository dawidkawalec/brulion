#!/bin/bash
# One-time setup of a stable local code signing identity ("Brulion Dev").
# Development identity only; releases use Developer ID, see docs/release.md.
#
# Ad-hoc signatures change with every build, so macOS drops the Microphone and
# Accessibility grants after each rebuild. A self-signed certificate gives the app
# a designated requirement based on the certificate instead of the binary hash,
# so the grants survive rebuilds. Local development only: distribution needs a
# Developer ID certificate and notarization.
#
# The identity lives in its own keychain (brulion-dev.keychain-db), kept OUT of the
# user keychain search list: `make sign` adds it only for the codesign call, because
# a keychain in the list offers its certificate in VPN and browser client-certificate
# prompts. Its password is kept outside the repo.
set -euo pipefail

NAME="Brulion Dev"
KC="$HOME/Library/Keychains/brulion-dev.keychain-db"
PWF="$HOME/.claude/secrets/brulion-dev-keychain.key"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# `pkcs12 -legacy` (the 3DES/SHA1 bundle `security import` accepts) needs OpenSSL 3 or later. The
# system /usr/bin/openssl is LibreSSL without that flag, so prefer Homebrew's and say so when it
# is missing (the commands below hide their output, so a wrong openssl used to fail silently).
OPENSSL="/opt/homebrew/bin/openssl"
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl)"
if ! "$OPENSSL" version | grep -q '^OpenSSL '; then
  echo "error: needs OpenSSL, not LibreSSL, for 'pkcs12 -legacy' (found: $("$OPENSSL" version)); run: brew install openssl" >&2
  exit 1
fi

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists in $KC"
  exit 0
fi

mkdir -p "$(dirname "$PWF")"
if [ ! -f "$PWF" ]; then
  (umask 077; "$OPENSSL" rand -hex 24 > "$PWF")
fi
PW="$(cat "$PWF")"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout pass:"$PW" 2>/dev/null

[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null

security find-identity -p codesigning "$KC"
echo "Done. Run 'make release' and grant Microphone + Accessibility once more."
