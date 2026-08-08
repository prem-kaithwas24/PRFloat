#!/usr/bin/env bash
# Notarize dist/PRFloat.app with Apple and staple the ticket.
#
# Requires an Apple Developer Program membership. This machine currently has no signing
# identity (`security find-identity -v -p codesigning` reports none), so this script is
# wired up but cannot run until one exists. Ad-hoc builds from package-app.sh work
# locally without it.
#
# Usage:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE="prfloat"       # see `xcrun notarytool store-credentials`
#   ./scripts/package-app.sh release
#   ./scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/PRFloat.app"
ZIP="$ROOT/dist/PRFloat.zip"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — run ./scripts/package-app.sh first" >&2
  exit 1
fi

: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

if ! security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID"; then
  echo "error: no codesigning identity matching '$DEVELOPER_ID' in the keychain" >&2
  echo "       run: security find-identity -v -p codesigning" >&2
  exit 1
fi

echo "→ Re-signing with hardened runtime"
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "→ Creating archive for submission"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Submitting to Apple (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "→ Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "→ Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$ZIP"
echo "→ Notarized: $APP"
