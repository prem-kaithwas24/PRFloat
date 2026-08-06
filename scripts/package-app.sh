#!/usr/bin/env bash
# Build PRFloat and wrap it as a macOS .app bundle (menu bar + floating panel).
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

echo "→ Assembling $BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
# PkgInfo is optional but traditional
printf 'APPL????' > "$CONTENTS/PkgInfo"

chmod +x "$MACOS_DIR/$APP_NAME"

echo "→ Done: $BUNDLE_DIR"
echo "  Open with: open \"$BUNDLE_DIR\""
echo "  Or copy to /Applications"
