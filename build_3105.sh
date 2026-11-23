#!/usr/bin/env bash
# Rebuild 3105 from source -> unsigned IPA. Requires macOS + Xcode (iOS SDK).
# Usage: bash build_3105.sh [path-to-3105-source] [output.ipa]
set -euo pipefail

SRC="${1:-./3105}"
OUT="${2:-3105-unsigned.ipa}"

command -v xcodebuild >/dev/null 2>&1 || { echo "ERROR: macOS + Xcode (xcodebuild) required." >&2; exit 1; }
[ -d "$SRC/ThreeOneOSFive.xcodeproj" ] || { echo "ERROR: xcodeproj not found in: $SRC" >&2; exit 1; }

# Hide the Home tab as well: only Installed remains visible.
python3 - <<'PY'
from pathlib import Path

ui = Path("ThreeOneOSFive/helpers/AppTabNavigationState.swift")
s = ui.read_text()
old = "        case .home, .installed:\n            return true\n"
new = "        case .installed:\n            return true\n"
assert old in s, "visible home pattern not found"
s = s.replace(old, new, 1)
old = "        case .new, .sources, .search:\n            return false\n"
new = "        case .home, .new, .sources, .search:\n            return false\n"
assert old in s, "hidden sections pattern not found"
s = s.replace(old, new, 1)
old = "            selectedTab = AppSection.home.rawValue\n"
new = "            selectedTab = AppSection.installed.rawValue\n"
assert old in s, "reconcile fallback not found"
s = s.replace(old, new, 1)
old = "        selectedTab: Int = 0,\n"
new = "        selectedTab: Int = AppSection.installed.rawValue,\n"
assert old in s, "initial tab not found"
s = s.replace(old, new, 1)
ui.write_text(s)

cv = Path("ThreeOneOSFive/ContentView.swift")
s = cv.read_text()
old = "        } ?? .home\n"
new = "        } ?? .installed\n"
assert old in s, "detail fallback not found"
cv.write_text(s.replace(old, new, 1))

ap = Path("ThreeOneOSFive/App.swift")
s = ap.read_text()
old = "    @State private var showOnboarding = OnboardingStore.shouldShow()\n"
new = "    @State private var showOnboarding = false\n"
assert old in s, "onboarding gate not found"
ap.write_text(s.replace(old, new, 1))
print("home tab hidden; onboarding skipped")
PY

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
