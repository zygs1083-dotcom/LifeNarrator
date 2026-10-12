#!/bin/bash
# Create a self-signed code signing identity for development builds, kept in a
# project-local keychain file (.dev-data/signing/dev.keychain-db). The login keychain
# is not touched. A stable identity keeps Accessibility / Screen Recording grants
# across rebuilds. Run once; scripts/bundle.sh --debug uses it when present.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="$PWD/.dev-data/signing"
KEYCHAIN="$DIR/dev.keychain-db"
PASS=lifenarrator-dev
NAME="LifeNarrator Dev"

mkdir -p "$DIR"
cd "$DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout key.pem -out cert.pem \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey key.pem -in cert.pem -out dev.p12 -passout "pass:$PASS"

security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import dev.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null
rm key.pem dev.p12
echo "identity '$NAME' in $KEYCHAIN"
