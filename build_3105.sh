#!/usr/bin/env bash
# Rebuild 3105 from source -> unsigned IPA. Requires macOS + Xcode (iOS SDK).
# Usage: bash build_3105.sh [path-to-3105-source] [output.ipa]
set -euo pipefail

SRC="${1:-./3105}"
OUT="${2:-3105-unsigned.ipa}"

command -v xcodebuild >/dev/null 2>&1 || { echo "ERROR: macOS + Xcode (xcodebuild) required." >&2; exit 1; }
[ -d "$SRC/ThreeOneOSFive.xcodeproj" ] || { echo "ERROR: xcodeproj not found in: $SRC" >&2; exit 1; }

python3 - <<'PY'
from pathlib import Path

# Only Installed (renamed AIM) + the 3 category tabs stay visible.
ui = Path("ThreeOneOSFive/helpers/AppTabNavigationState.swift")
s = ui.read_text()
old = "        case .home, .installed:\n            return true\n"
new = "        case .installed:\n            return true\n"
assert old in s, "visible home pattern not found"
s = s.replace(old, new, 1)
old = "        case .new, .sources, .search:\n            return false\n"
new = "        case .home, .new, .sources, .search, .hologram, .skin, .misc:\n            return false\n"
assert old in s, "hidden sections pattern not found"
s = s.replace(old, new, 1)
old = "    case search\n\n    var id: Int { rawValue }"
new = "    case search\n    case hologram\n    case skin\n    case misc\n\n    var id: Int { rawValue }"
assert old in s, "AppSection cases not found"
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
old = "import UIKit\n"
new = "import UIKit\nimport UniformTypeIdentifiers\n"
assert old in s, "UIKit import not found"
s = s.replace(old, new, 1)
old = "        } ?? .home\n"
new = "        } ?? .installed\n"
assert old in s, "detail fallback not found"
s = s.replace(old, new, 1)
old = '        case .installed: return "tab.installed"\n'
new = '        case .installed: return "AIM"\n        case .hologram: return "HOLOGRAM"\n        case .skin: return "SKIN"\n        case .misc: return "MISC"\n'
assert old in s, "titleKey pattern not found"
s = s.replace(old, new, 1)
old = '        case .installed: return "tray.full.fill"\n'
new = '        case .installed: return "tray.full.fill"\n        case .hologram: return "cube.transparent.fill"\n        case .skin: return "paintbrush.fill"\n        case .misc: return "square.grid.2x2.fill"\n'
assert old in s, "systemImage pattern not found"
s = s.replace(old, new, 1)
old = "        case .installed:\n            PatchProjectsView(\n                onOpenSettings: openSettings,\n                onOpenLogs: openLogs\n            )\n"
new = old + "        case .hologram:\n            AimCategoryView(title: \"HOLOGRAM\")\n        case .skin:\n            AimCategoryView(title: \"SKIN\")\n        case .misc:\n            AimCategoryView(title: \"MISC\")\n"
assert old in s, "sectionContent pattern not found"
s = s.replace(old, new, 1)
s += """
private struct AimCategoryView: View {
    let title: String
    var body: some View { EmptyView() }
}
"""
cv.write_text(s)

# Replace placeholder with real .3105 importers scoped per category.
cv = Path("ThreeOneOSFive/ContentView.swift")
s = cv.read_text()
idx = s.find("private struct AimCategoryView: View {")
assert idx >= 0, "placeholder category view not found"
s = s[:idx]
s += '''
private struct AimCategoryView: View {
    let title: String
    @EnvironmentObject private var patchStore: PatchProjectStore
    @State private var showImporter = false

    private var storageKey: String { "aim.category." + title.lowercased() }

    private var categoryIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    private var items: [PatchLibraryItem] {
        let ids = categoryIDs
        return patchStore.items.filter { ids.contains($0.id.uuidString) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "shippingbox.and.arrow.backward")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(AppTheme.accent)
                        Text("No patches in " + title)
                            .font(.headline)
                        Text("Tap + to import a .3105 patch.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.isLocked ? "lock.fill" : "shippingbox.fill")
                                    .foregroundStyle(AppTheme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.project?.name ?? "Locked patch")
                                        .font(.subheadline.weight(.semibold))
                                    Text(item.isLocked ? "Password required" : (item.project?.author ?? ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import .3105")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result,
                      let url = urls.first,
                      url.pathExtension.lowercased() == "3105" else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                let data = try? PatchProjectLibrary.readPackage(at: url)
                let packageID = data.flatMap { try? PatchPackageCodec.inspect($0) }?.packageID
                if let packageID {
                    var ids = categoryIDs
                    ids.insert(packageID.uuidString)
                    UserDefaults.standard.set(Array(ids), forKey: storageKey)
                }
                patchStore.importPackage(at: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }
}
'''
cv.write_text(s)

ap = Path("ThreeOneOSFive/App.swift")
s = ap.read_text()
old = "    @State private var showOnboarding = OnboardingStore.shouldShow()\n"
new = "    @State private var showOnboarding = false\n"
assert old in s, "onboarding gate not found"
ap.write_text(s.replace(old, new, 1))

# Remove the Installed title and the Cleaner utility row.
pv = Path("ThreeOneOSFive/views/PatchProjectsView.swift")
s = pv.read_text()
old = '            .navigationTitle(language.text("tab.installed"))\n'
new = '            .navigationTitle("")\n'
assert old in s, "installed title not found"
s = s.replace(old, new, 1)
old = "                    if cleanerEnabled {\n                        Section(language.text(\"repository.utilities\")) {\n                            cleanerRow\n                        }\n                    }\n"
assert old in s, "cleaner section not found"
s = s.replace(old, "", 1)
pv.write_text(s)

# Remove the top settings gear; Settings moves into the bottom tab bar.
ut = Path("ThreeOneOSFive/views/RepositoryMarketplaceView.swift")
s = ut.read_text()
anchor = s.find("struct AppUtilityToolbar")
assert anchor >= 0, "utility toolbar definition not found"
start = s.find("        ToolbarItem(placement: .navigationBarTrailing) {\n            Menu {", anchor)
assert start >= 0, "utility toolbar item not found"
end_marker = '            .accessibilityLabel(language.text("accessibility.open_settings"))\n'
end = s.find(end_marker, start)
assert end >= 0, "utility toolbar end not found"
end += len(end_marker)
close = s.find("        }\n", end)
assert close >= 0, "toolbar item close not found"
close += len("        }\n")
s = s[:start] + "        ToolbarItem(placement: .navigationBarTrailing) {\n            EmptyView()\n        }\n" + s[close:]
ut.write_text(s)

# Add a Settings tab at the end of the bottom bar.
ui = Path("ThreeOneOSFive/helpers/AppTabNavigationState.swift")
s = ui.read_text()
old = "    case misc\n\n    var id: Int { rawValue }"
new = "    case misc\n    case settings\n\n    var id: Int { rawValue }"
assert old in s, "misc case not found"
s = s.replace(old, new, 1)
old = "        case .installed:\n            return true\n"
new = "        case .installed, .settings:\n            return true\n"
assert old in s, "installed visibility not found"
s = s.replace(old, new, 1)
ui.write_text(s)

cv = Path("ThreeOneOSFive/ContentView.swift")
s = cv.read_text()
old = '        case .misc: return "MISC"\n'
new = old + '        case .settings: return "settings.title"\n'
assert old in s, "misc title not found"
s = s.replace(old, new, 1)
old = '        case .misc: return "square.grid.2x2.fill"\n'
new = old + '        case .settings: return "gearshape.fill"\n'
assert old in s, "misc icon not found"
s = s.replace(old, new, 1)
old = '        case .misc:\n            AimCategoryView(title: "MISC")\n'
new = old + '        case .settings:\n            SettingsView()\n'
assert old in s, "misc section not found"
s = s.replace(old, new, 1)
cv.write_text(s)
print("Installed title removed; Cleaner removed; Settings tab added")
PY

BUILD_ROOT="$SRC/.build"
rm -rf "$BUILD_ROOT"

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
