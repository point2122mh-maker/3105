#!/usr/bin/env bash
# Rebuild 3105 from source -> unsigned IPA. Requires macOS + Xcode (iOS SDK).
# Usage: bash build_3105.sh [path-to-3105-source] [output.ipa]
set -euo pipefail

SRC="${1:-./3105}"
OUT="${2:-3105-unsigned.ipa}"

command -v xcodebuild >/dev/null 2>&1 || { echo "ERROR: macOS + Xcode (xcodebuild) required." >&2; exit 1; }
[ -d "$SRC/ThreeOneOSFive.xcodeproj" ] || { echo "ERROR: xcodeproj not found in: $SRC" >&2; exit 1; }

BUILD_ROOT="$SRC/.build"
rm -rf "$BUILD_ROOT"

# No shared .xcscheme in repo -> build by target, then package the .app ourselves.
xcodebuild \
  -project "$SRC/ThreeOneOSFive.xcodeproj" \
  -target 3105 \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  SYMROOT="$BUILD_ROOT" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP="$(find "$BUILD_ROOT/Release-iphoneos" -maxdepth 1 -name '3105.app' -print -quit)"
[ -n "$APP" ] || { echo "ERROR: 3105.app was not produced." >&2; exit 1; }

DEST_DIR="$(cd "$(dirname "$OUT")" && pwd)"
DEST="$DEST_DIR/$(basename "$OUT")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Payload"
cp -R "$APP" "$TMP/Payload/3105.app"
(cd "$TMP" && zip -qry "$DEST" Payload)

echo "OK: $DEST"
shasum -a 256 "$DEST" 2>/dev/null || shasum -a 256 "$DEST"
