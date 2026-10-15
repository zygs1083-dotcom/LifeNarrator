#!/bin/bash
set -euo pipefail

fail() { echo "LifeNarrator: $*" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail "This installer requires macOS."

work=$(mktemp -d)
staging=
app=
installed=false
committed=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ $committed == false && -n $staging ]]; then
    if [[ -e "$staging/previous.app" ]]; then
      rm -rf "$app"
      mv "$staging/previous.app" "$app"
    elif [[ $installed == true ]]; then
      rm -rf "$app"
    fi
  fi
  rm -rf "$work"
  if [[ -n $staging ]]; then rm -rf "$staging"; fi
  if (( status != 0 )); then echo "LifeNarrator: Installation failed (exit $status)." >&2; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'echo "LifeNarrator: Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

api=https://api.github.com/repos/zygs1083-dotcom/LifeNarrator/releases
if [[ -n ${LIFENARRATOR_VERSION:-} ]]; then
  [[ $LIFENARRATOR_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][a-zA-Z0-9.+-]+)?$ ]] || fail "Invalid LIFENARRATOR_VERSION."
  api="$api/tags/$LIFENARRATOR_VERSION"
else
  api="$api/latest"
fi
curl -fsSL "$api" -o "$work/release.json"
# JavaScript for Automation ships with macOS; no jq or Python installation is needed.
asset_url() {
  osascript -l JavaScript - "$work/release.json" "$1" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  const release = JSON.parse(ObjC.unwrap(text));
  const asset = release.assets.find(function(asset) { return asset.name === argv[1]; });
  if (!asset) throw new Error('Release is missing ' + argv[1]);
  if (!/^https:\/\/github\.com\/zygs1083-dotcom\/LifeNarrator\/releases\/download\//.test(asset.browser_download_url)) {
    throw new Error('Invalid asset URL: ' + asset.browser_download_url);
  }
  return asset.browser_download_url;
}
JXA
}
zip_url=$(asset_url LifeNarrator.zip)
checksums_url=$(asset_url checksums.txt)
curl -fsSL "$zip_url" -o "$work/LifeNarrator.zip"
curl -fsSL "$checksums_url" -o "$work/checksums.txt"
awk '$2 == "LifeNarrator.zip" || $2 == "*LifeNarrator.zip" { print; found++ } END { if (found != 1) exit 1 }' \
  "$work/checksums.txt" > "$work/zip.sha256" || fail "Expected exactly one LifeNarrator.zip checksum."
(cd "$work" && shasum -a 256 -c zip.sha256) || fail "SHA-256 verification failed."
ditto -x -k "$work/LifeNarrator.zip" "$work/unpacked"
[[ -d "$work/unpacked/LifeNarrator.app/Contents/MacOS" ]] || fail "Archive is missing LifeNarrator.app."

install_dir=/Applications
if [[ ! -w $install_dir ]]; then install_dir="$HOME/Applications"; fi
mkdir -p "$install_dir"
app="$install_dir/LifeNarrator.app"
staging=$(mktemp -d "$install_dir/.LifeNarrator.XXXXXX")
ditto "$work/unpacked/LifeNarrator.app" "$staging/new.app"
xattr -dr com.apple.quarantine "$staging/new.app"
# SIGTERM instead of an Apple Event: quitting another app with osascript asks for Automation permission.
if pgrep -x LifeNarrator >/dev/null; then
  pkill -x LifeNarrator
  for ((i=0; i<10; i++)); do
    if ! pgrep -x LifeNarrator >/dev/null; then break; fi
    sleep 1
  done
  if pgrep -x LifeNarrator >/dev/null; then
    fail "LifeNarrator did not quit within 10 seconds. Quit it and run the installer again."
  fi
fi
if [[ -e $app ]]; then mv "$app" "$staging/previous.app"; fi
installed=true
mv "$staging/new.app" "$app"
open "$app"
committed=true
echo "LifeNarrator installed at $app"
