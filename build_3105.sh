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

# Rename Installed -> AIM and add HOLOGRAM / SKIN / MISC tabs.
ui = Path("ThreeOneOSFive/helpers/AppTabNavigationState.swift")
s = ui.read_text()
old = "    case search\n\n    var id: Int { rawValue }"
new = "    case search\n    case hologram\n    case skin\n    case misc\n\n    var id: Int { rawValue }"
assert old in s, "AppSection cases not found"
s = s.replace(old, new, 1)
old = "        case .installed:\n            return true\n"
new = "        case .installed, .hologram, .skin, .misc:\n            return true\n"
assert old in s, "visibility installed case not found"
s = s.replace(old, new, 1)
ui.write_text(s)

cv = Path("ThreeOneOSFive/ContentView.swift")
s = cv.read_text()
old = '        case .installed: return "tab.installed"\n'
new = '        case .installed: return "AIM"\n        case .hologram: return "HOLOGRAM"\n        case .skin: return "SKIN"\n        case .misc: return "MISC"\n'
assert old in s, "titleKey installed not found"
s = s.replace(old, new, 1)
old = '        case .installed: return "tray.full.fill"\n'
new = '        case .installed: return "tray.full.fill"\n        case .hologram: return "cube.transparent.fill"\n        case .skin: return "paintbrush.fill"\n        case .misc: return "square.grid.2x2.fill"\n'
assert old in s, "systemImage installed not found"
s = s.replace(old, new, 1)
old = "        case .installed:\n            PatchProjectsView(\n                onOpenSettings: openSettings,\n                onOpenLogs: openLogs\n            )\n"
new = old + "        case .hologram:\n            AimCategoryView(title: \"HOLOGRAM\")\n        case .skin:\n            AimCategoryView(title: \"SKIN\")\n        case .misc:\n            AimCategoryView(title: \"MISC\")\n"
assert old in s, "sectionContent installed not found"
s = s.replace(old, new, 1)
s += """
private struct AimCategoryView: View {
    let title: String
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.headline)
                Text("No items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
"""
cv.write_text(s)

# Give SKIN / HOLOGRAM / MISC real file storage with an Add (+) importer.
cv = Path("ThreeOneOSFive/ContentView.swift")
s = cv.read_text()
old = "import UIKit\n"
new = "import UIKit\nimport UniformTypeIdentifiers\n"
assert old in s, "UIKit import not found"
s = s.replace(old, new, 1)
idx = s.find("private struct AimCategoryView: View {")
assert idx >= 0, "placeholder category view not found"
s = s[:idx]
s += '''
private struct AimFileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var size: Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { Int64($0) } ?? 0
    }
}

private final class AimFileStore: ObservableObject {
    @Published private(set) var files: [AimFileItem] = []
    let category: String

    init(category: String) {
        self.category = category
        reload()
    }

    private var directory: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        return docs
            .appendingPathComponent("AIM", isDirectory: true)
            .appendingPathComponent(category, isDirectory: true)
    }

    func reload() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        files = contents
            .map { AimFileItem(url: $0) }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func add(urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try? FileManager.default.copyItem(at: url, to: destination)
        }
        reload()
    }

    func delete(_ item: AimFileItem) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }
}

private struct AimCategoryView: View {
    let title: String
    @StateObject private var store: AimFileStore
    @State private var showImporter = false

    init(title: String) {
        self.title = title
        _store = StateObject(wrappedValue: AimFileStore(category: title))
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(AppTheme.accent)
                        Text("No files in \\(title)")
                            .font(.headline)
                        Text("Tap + to add files.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.files) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(AppTheme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(formatSize(item.size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
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
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add file")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    store.add(urls: urls)
                }
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\\(bytes) B" }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
'''
cv.write_text(s)
print("AIM file categories enabled; onboarding skipped")
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
