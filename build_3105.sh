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
new = "        case .home, .new, .sources, .search:\n            return false\n"
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
new = "        case .installed, .hologram, .skin, .misc, .settings:\n            return true\n"
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

# Remove the + menu from AIM.
pv = Path("ThreeOneOSFive/views/PatchProjectsView.swift")
s = pv.read_text()
start = s.find("                ToolbarItem(placement: .navigationBarTrailing) {\n                    Menu {")
assert start >= 0, "add menu not found"
end_marker = '                .accessibilityLabel(language.text("patch.add"))\n'
end = s.find(end_marker, start)
assert end >= 0, "add menu end not found"
end += len(end_marker)
close = s.find("                }\n", end)
assert close >= 0, "add menu close not found"
close += len("                }\n")
s = s[:start] + "                ToolbarItem(placement: .navigationBarTrailing) {\n                    EmptyView()\n                }\n" + s[close:]
pv.write_text(s)

# Category tabs read from the app shared Documents folder (Files app), no + button.
cv = Path("ThreeOneOSFive/ContentView.swift")
s = cv.read_text()
idx = s.find("private struct AimCategoryView: View {")
assert idx >= 0, "category view not found"
s = s[:idx]
s += '''
private struct AimCategoryView: View {
    let title: String
    @EnvironmentObject private var patchStore: PatchProjectStore
    @State private var fileURLs: [URL] = []

    private var folderURL: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
)[0]
        return docs.appendingPathComponent(title, isDirectory: true)
    }

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
                if fileURLs.isEmpty && items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(AppTheme.accent)
                        Text("No files in " + title)
                            .font(.headline)
                        Text("Files app > 3105 > " + title + " - drop .3105 files here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                } else {
                    List {
                        if !items.isEmpty {
                            Section("Patches") {
                                ForEach(items) { item in
                                    HStack(spacing: 12) {
                                        Image(systemName: item.isLocked ? "lock.fill" : "shippingbox.fill")
                                            .foregroundStyle(AppTheme.accent)
                                        Text(item.project?.name ?? "Locked patch")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }
                            }
                        }
                        if !fileURLs.isEmpty {
                            Section("Files") {
                                ForEach(fileURLs, id: \.self) { url in
                                    Button {
                                        importFile(url)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "doc.fill")
                                                .foregroundStyle(AppTheme.accent)
                                            Text(url.lastPathComponent)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    .buttonStyle(.plain)
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
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        try? FileManager.default.createDirectory(
            at: folderURL, withIntermediateDirectories: true
)
        fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
)) ?? []
    }

    private func importFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let summary = try? PatchPackageCodec.inspect(data) else { return }
        var ids = categoryIDs
        ids.insert(summary.packageID.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: storageKey)
        patchStore.importPackage(at: url)
    }
}
'''
cv.write_text(s)

# Built-in HTTP file server: upload from Safari without rebuilding the IPA.
info = Path("ThreeOneOSFive/Info.plist")
s = info.read_text()
old = "</dict>\n</plist>"
new = "    <key>NSLocalNetworkUsageDescription</key>\n    <string>AIM file server receives uploads from your browser.</string>\n</dict>\n</plist>"
assert old in s, "Info.plist tail not found"
info.write_text(s.replace(old, new, 1))

cv = Path("ThreeOneOSFive/ContentView.swift")
s = cv.read_text()
old = "import UIKit\nimport UniformTypeIdentifiers\n"
new = "import UIKit\nimport UniformTypeIdentifiers\nimport Network\nimport Darwin\n"
assert old in s, "imports not found"
s = s.replace(old, new, 1)
s += r'''
private final class AimFileServer: ObservableObject {
    static let shared = AimFileServer()
    @Published private(set) var isRunning = false
    @Published private(set) var url = ""
    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: 8085)!)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.url = "http://" + Self.localIP() + ":8085"
                    default:
                        self.isRunning = false
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private static func localIP() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "device" }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let addr = p.pointee.ifa_addr.pointee
            if addr.sa_family == AF_INET {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(p.pointee.ifa_addr, socklen_t(addr.sa_len),
                               &host, socklen_t(host.count), nil, 0,
                               NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" { return ip }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return "device"
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()

        func read() {
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: 65536) { data, _, complete, error in
                if let chunk = data { buffer.append(chunk) }
                if let end = Self.headerEnd(in: buffer) {
                    let header = String(
                        data: buffer.subdata(in: 0..<end), encoding: .utf8
) ?? ""
                    let lines = header.split(separator: "\r\n")
                    let request = lines.first.map(String.init) ?? ""
                    let parts = request.split(separator: " ")
                    let method = parts.first.map(String.init) ?? "GET"
                    let target = parts.count > 1 ? String(parts[1]) : "/"
                    var length = 0
                    for line in lines where line.lowercased().hasPrefix("content-length:") {
                        let value = line.split(separator: ":").last?
                            .trimmingCharacters(in: .whitespaces) ?? "0"
                        length = Int(value) ?? 0
                    }
                    let bodyStart = end + 4
                    if buffer.count >= bodyStart + length {
                        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
                        self.process(method: method, target: target,
                                body: body, connection: connection)
                        return
                    }
                }
                if complete || error != nil {
                    connection.cancel()
                    return
                }
                read()
            }
        }
        read()
    }

    private static func headerEnd(in data: Data) -> Int? {
        let needle = Array("\r\n\r\n".utf8)
        let bytes = [UInt8](data)
        guard bytes.count >= needle.count else { return nil }
        for i in 0...(bytes.count - needle.count) {
            if Array(bytes[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }

    private func process(method: String, target: String,
                         body: Data, connection: NWConnection) {
        var status = "200 OK"
        var pageHTML = ""
        if method == "POST", target.hasPrefix("/upload") {
            let pieces = target.split(separator: "?", maxSplits: 1)
            let query = pieces.count > 1 ? String(pieces[1]) : ""
            var category = "MISC"
            var filename = "upload.bin"
            for item in query.split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let key = String(pair[0])
                let raw = String(pair[1])
                let value = raw.removingPercentEncoding ?? raw
                if key == "cat" { category = value.uppercased() }
                if key == "name" { filename = (value as NSString).lastPathComponent }
            }
            let allowed = ["HOLOGRAM", "SKIN", "MISC"]
            if !allowed.contains(category) { category = "MISC" }
            if filename.isEmpty { filename = "upload.bin" }
            let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
)[0]
            let folder = docs.appendingPathComponent(category, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true
)
            do {
                try body.write(to: folder.appendingPathComponent(filename),
                               options: .atomic)
            } catch {
                status = "500 Internal Server Error"
            }
            pageHTML = "<html><body><h3>Saved</h3><a href='/'>Back</a></body></html>"
        } else {
            pageHTML = Self.page()
        }
        let response = "HTTP/1.1 " + status + "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + String(pageHTML.utf8.count) + "\r\nConnection: close\r\n\r\n" + pageHTML
        connection.send(content: response.data(using: .utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page() -> String {
        return "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><title>AIM Files</title></head><body style='background:#111;color:#eee;font-family:sans-serif;padding:20px'><h2>AIM File Server</h2><select id='cat'><option>HOLOGRAM</option><option>SKIN</option><option>MISC</option></select><p><input type='file' id='f'></p><button onclick='up()'>Upload</button><p id='s'></p><script>async function up(){const f=document.getElementById('f').files[0];if(!f){alert('choose a file');return;}const c=document.getElementById('cat').value;const r=await fetch('/upload?cat='+c+'&name='+encodeURIComponent(f.name),{method:'POST',body:f});document.getElementById('s').textContent=r.ok?('Saved '+f.name+' to '+c):'Failed';}</script></body></html>"
    }
}

struct AimFileServerSection: View {
    @ObservedObject private var server = AimFileServer.shared

    var body: some View {
        Section("AIM File Server") {
            Toggle("Enabled", isOn: Binding(
                get: { server.isRunning },
                set: { enabled in
                    if enabled { server.start() } else { server.stop() }
                }
            ))
            if server.isRunning {
                Text(server.url)
                    .font(.caption)
                    .textSelection(.enabled)
                Text("Open in Safari on the same Wi-Fi. Files go to Documents/HOLOGRAM, SKIN or MISC.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
'''
cv.write_text(s)

sv = Path("ThreeOneOSFive/views/SettingsView.swift")
s = sv.read_text()
old = "            Form {\n"
new = "            Form {\n                AimFileServerSection()\n"
assert old in s, "Settings form not found"
sv.write_text(s.replace(old, new, 1))
print("File server added; settings section wired")
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
