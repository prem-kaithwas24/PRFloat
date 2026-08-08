#!/usr/bin/env bash
# Build PRFloat and wrap it as a macOS .app bundle (menu bar + floating panel).
#
# Signing: uses a Developer ID identity when DEVELOPER_ID is set, otherwise falls back to
# an ad-hoc signature. Ad-hoc builds run fine locally but Gatekeeper will quarantine them
# when copied from another machine — see README.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-release}"
APP_NAME="PRFloat"
BUNDLE_DIR="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "→ Building ($CONFIGURATION)…"
if [[ "$CONFIGURATION" == "debug" ]]; then
  swift build
  BIN="$ROOT/.build/debug/$APP_NAME"
else
  swift build -c release
  BIN="$ROOT/.build/release/$APP_NAME"
fi

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

# Regenerate the icon when the generator is newer than the committed .icns.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "→ Rendering app icon…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  GENERATOR="$(mktemp -d)/make-icon"
  swiftc -O -o "$GENERATOR" "$ROOT/scripts/make-icon.swift"
  "$GENERATOR" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
fi

echo "→ Assembling $BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"
chmod +x "$MACOS_DIR/$APP_NAME"

# The client ID is not a secret (device flow has no client secret), so baking it into the
# bundle is safe and saves the user pasting it on first run.
if [[ -n "${PRFLOAT_GITHUB_CLIENT_ID:-}" ]]; then
  echo "→ Embedding GitHub client ID"
  /usr/libexec/PlistBuddy -c "Set :PRFloatGitHubClientID $PRFLOAT_GITHUB_CLIENT_ID" "$CONTENTS/Info.plist"
fi

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "→ Signing with Developer ID: $DEVELOPER_ID"
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$BUNDLE_DIR"
else
  echo "→ Signing ad-hoc (no DEVELOPER_ID set)"
  codesign --force --deep --sign - "$BUNDLE_DIR"
fi

codesign --verify --verbose=1 "$BUNDLE_DIR" 2>&1 | sed 's/^/  /'

echo "→ Done: $BUNDLE_DIR"
echo "  Open with: open \"$BUNDLE_DIR\""
echo "  Or copy to /Applications"
