#!/usr/bin/env bash
#
# Builds Boring Notch from this checkout and installs it into /Applications,
# replacing the installed copy. For personal use on this Mac.
#
# Signing: if a code-signing certificate named "Boring Notch Local Signing" (or
# $SIGNING_IDENTITY) is in the keychain, even a self-signed one, the app is signed with it, so macOS
# keeps its permissions across rebuilds. Otherwise the build is signed ad-hoc
# and macOS may ask again for Accessibility and other permissions after each install.
#
# Usage: scripts/install-local.sh

set -euo pipefail

BUNDLE_ID="theboringteam.boringnotch"
APP_NAME="Boring Notch.app"
LEGACY_APP="/Applications/boringNotch.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Boring Notch Local Signing}"
DEST="/Applications/$APP_NAME"

REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
DERIVED_DATA="$REPO/build/local"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"

fail() { echo "error: $*" >&2; exit 1; }

# Sparkle would replace this build with the next upstream release.
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate; do
    if [ "$(defaults read "$BUNDLE_ID" "$key" 2>/dev/null || echo 0)" = "1" ]; then
        fail "automatic updates are on ($key), so the official release would overwrite this build.
Turn them off in the app's settings, or run:
  defaults write $BUNDLE_ID SUEnableAutomaticChecks -bool false
  defaults write $BUNDLE_ID SUAutomaticallyUpdate -bool false"
    fi
done

# Two copies would confuse the app's own legacy-name migration.
if [ -e "$LEGACY_APP" ]; then
    fail "$LEGACY_APP exists. Move it to the Trash first, so only $DEST remains."
fi

if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
    echo "warning: uncommitted changes are included in this build" >&2
fi

echo "Building $(git -C "$REPO" rev-parse --abbrev-ref HEAD) @ $(git -C "$REPO" rev-parse --short HEAD)..."
if security find-identity -v -p codesigning | grep -qF "\"$SIGNING_IDENTITY\""; then
    echo "Signing with \"$SIGNING_IDENTITY\"."
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
else
    echo "warning: no \"$SIGNING_IDENTITY\" certificate, signing ad-hoc" >&2
    SIGNING=(CODE_SIGN_IDENTITY=-)
fi

# Hardened Runtime is off because neither an ad-hoc nor a self-signed certificate has a
# Team ID, and library validation would then reject the embedded MediaRemoteAdapter.framework
# at launch. With an Apple Development certificate, drop this override and pass DEVELOPMENT_TEAM.
xcodebuild -project "$REPO/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED_DATA" -quiet \
    ENABLE_HARDENED_RUNTIME=NO "${SIGNING[@]}" build
[ -d "$BUILT_APP" ] || fail "build succeeded but $BUILT_APP is missing"

if pgrep -xq "Boring Notch"; then
    echo "Quitting the running app..."
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -xq "Boring Notch" || break
        sleep 0.5
    done
    pgrep -xq "Boring Notch" && fail "the app did not quit; quit it manually and run again"
fi

echo "Installing to $DEST..."
rm -rf "$DEST.new"
ditto "$BUILT_APP" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"

open "$DEST"
echo "Done. Installed and launched $DEST."
