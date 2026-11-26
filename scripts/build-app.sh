#!/bin/zsh
# Builds CD with SwiftPM, assembles build/CD.app, signs it, installs it in /Applications
# (replacing the copy there) and launches it.
#   scripts/build-app.sh               build, sign, install
#   NO_INSTALL=1 scripts/build-app.sh  only build/CD.app
#
# Signing uses the local identity in signing/ (scripts/setup-signing.sh creates it), so macOS
# keeps folder permissions across rebuilds. ADHOC=1 signs ad hoc instead.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f Resources/AppIcon.icns ]]; then
    WORK=$(mktemp -d)
    swift scripts/make-icon.swift "$WORK"
    iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
    cp "$WORK/icon-preview.png" Resources/icon-preview.png
    rm -rf "$WORK"
fi

swift build -c release
APP="build/CD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CD "$APP/Contents/MacOS/CD"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

ID="local.cd.CD"
KC="$PWD/signing/cd.keychain-db"
sign_all() {   # codesign options...
    codesign --force "$@" --identifier "$ID" "$APP"
}
if [[ "${ADHOC:-0}" == "1" ]]; then
    sign_all --sign -
elif [[ -f "$KC" ]]; then
    security unlock-keychain -p cdplayer "$KC"
    # codesign only finds identities in keychains on the search list: add ours for the duration.
    OLD=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
    security list-keychains -d user -s "${OLD[@]}" "$KC"
    sign_all --keychain "$KC" --sign "CD Local Signing" || STATUS=$?
    security list-keychains -d user -s "${OLD[@]}"
    [[ -z "${STATUS:-}" ]] || exit $STATUS
else
    echo "error: signing/cd.keychain-db not found. Run scripts/setup-signing.sh, or ADHOC=1." >&2
    exit 1
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

if [[ "${NO_INSTALL:-0}" != "1" ]]; then
    osascript -e 'tell application id "local.cd.CD" to quit' 2>/dev/null || true
    rm -rf "/Applications/CD.app"
    ditto "$APP" "/Applications/CD.app"
    open "/Applications/CD.app"
    echo "Installed and launched /Applications/CD.app"
else
    echo "Built $PWD/$APP"
fi
