#!/bin/bash
# Build LifeNarrator.app (ad-hoc signed) and zip it into dist/.
# Usage: scripts/bundle.sh [--debug]   (--debug uses bundle id dev.lifenarrator.debug)
# SIGN_IDENTITY picks the signing certificate; CI sets it, local builds stay ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Release
BUNDLE_ID=dev.lifenarrator.app
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG=Debug
  BUNDLE_ID=dev.lifenarrator.debug
fi

VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/NarratorCore/NarratorCore.swift)
# xcodebuild, not `swift build`: SwiftPM's generated Bundle.module only looks at the .app root, where code
# signing allows no extra files; Xcode's looks in Contents/Resources. This also covers KeyboardShortcuts.
xcodebuild -scheme LifeNarrator -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode -quiet build
BIN_DIR=.build/xcode/Build/Products/$CONFIG

APP=dist/LifeNarrator.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/LifeNarrator" "$APP/Contents/MacOS/"
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
find "$BIN_DIR" -maxdepth 1 -name '*.framework' -exec cp -R {} "$APP/Contents/Frameworks/" \;
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/LifeNarrator"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LifeNarrator</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>LifeNarrator</string>
  <key>CFBundleDisplayName</key><string>LifeNarrator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
(cd dist && rm -f LifeNarrator.zip && ditto -c -k --keepParent LifeNarrator.app LifeNarrator.zip)
echo "dist/LifeNarrator.app  dist/LifeNarrator.zip"
