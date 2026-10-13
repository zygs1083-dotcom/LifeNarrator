#!/bin/bash
# CI only: import the self-signed code signing certificate into a temporary keychain.
# A fixed certificate keeps the app's code signing identity stable across releases,
# so macOS keeps the Accessibility permission after an update.
# Needs MACOS_SIGNING_P12 (base64) and MACOS_SIGNING_PASSWORD.
set -euo pipefail

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
echo "$MACOS_SIGNING_P12" | base64 --decode > "$RUNNER_TEMP/signing.p12"
security create-keychain -p "" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "" "$KEYCHAIN"
security import "$RUNNER_TEMP/signing.p12" -k "$KEYCHAIN" -P "$MACOS_SIGNING_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" > /dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
# codesign only uses identities whose certificate is trusted for code signing.
security find-certificate -c "LifeNarrator Self-Signed" -p "$KEYCHAIN" > "$RUNNER_TEMP/signing.pem"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$RUNNER_TEMP/signing.pem"
rm "$RUNNER_TEMP/signing.p12"
