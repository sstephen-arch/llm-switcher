import AppKit
import CryptoKit
import Foundation

/// Checks oMLX's GitHub releases and upgrades oMLX safely: the download must match GitHub's
/// SHA-256, be notarized, and be signed by oMLX's developer (team PSK5Q5T46L, the same as the copy
/// already installed). It waits until oMLX is idle before quitting it, keeps the old app in the
/// Trash, and only then installs the new one.
@MainActor
final class OMLXUpdater: ObservableObject {
    struct Release: Identifiable, Equatable {
        var id: String { tag }
        let tag: String           // v0.7.1.dev1
        let version: String       // 0.7.1.dev1
        let date: String
        let isDev: Bool
        let dmgURL: URL?
        let dmgSize: Int64
        let sha256: String?
        let notes: String
    }

    static let teamID = "PSK5Q5T46L"
    static let bundleID = "app.omlx"

    @Published var releases: [Release] = []
    @Published var checking = false
    @Published var status: String?
    @Published var error: String?

    static func installedVersion() -> String {
        (Bundle(url: OMLX.appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ((NSDictionary(contentsOf: OMLX.appURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "not installed")
    }

    var installed: String { Self.installedVersion() }
    var latestStable: Release? { releases.first { !$0.isDev } }
    var latestDev: Release? { releases.first }

    /// Newer releases than the installed one (GitHub lists newest first).
    func newer(includeDev: Bool) -> Release? {
        guard let idx = releases.firstIndex(where: { $0.version == installed }) else {
            return includeDev ? latestDev : latestStable
        }
        return releases[..<idx].first { includeDev || !$0.isDev }
    }

    func check() async {
        checking = true
        defer { checking = false }
        error = nil
        guard let url = URL(string: "https://api.github.com/repos/jundot/omlx/releases?per_page=15"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            error = "Couldn't reach GitHub to check for oMLX updates"
            return
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let suffix = os >= 26 ? "macos26-27.dmg" : "macos15-sequoia.dmg"
        releases = list.compactMap { r in
            guard let tag = r["tag_name"] as? String, (r["draft"] as? Bool) != true else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let asset = (r["assets"] as? [[String: Any]] ?? []).first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
            let digest = (asset?["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
            let isDev = (r["prerelease"] as? Bool) == true || version.contains("dev") || version.contains("rc")
            return Release(tag: tag, version: version, date: String((r["published_at"] as? String ?? "").prefix(10)), isDev: isDev,
                           dmgURL: (asset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                           dmgSize: (asset?["size"] as? NSNumber)?.int64Value ?? 0, sha256: digest,
                           notes: String((r["body"] as? String ?? "").prefix(4000)))
        }
    }

    // MARK: install

    func install(_ r: Release, upstream: String) async {
        error = nil
        do {
            guard let url = r.dmgURL, let expected = r.sha256 else { throw fail("This release has no installer for this macOS version") }
            status = "Downloading oMLX \(r.version) (\(ByteCountFormatter.string(fromByteCount: r.dmgSize, countStyle: .file)))…"
            let dmg = try await download(url, size: r.dmgSize)
            defer { try? FileManager.default.removeItem(at: dmg) }
            status = "Checking the download…"
            let digest = try await Task.detached { () -> String in
                let h = try FileHandle(forReadingFrom: dmg)
                defer { try? h.close() }
                var hasher = SHA256()
                while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
            guard digest == expected.lowercased() else { throw fail("The download doesn't match GitHub's checksum; nothing was changed") }

            let mount = try await attach(dmg)
            defer { _ = try? Self.exec("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }
            let newApp = URL(fileURLWithPath: mount).appendingPathComponent("oMLX.app")
            try await verify(newApp)

            // Copy the new app next to the old one first, so a failed copy never leaves you without oMLX.
            status = "Preparing oMLX \(r.version)…"
            let staged = OMLX.appURL.deletingLastPathComponent().appendingPathComponent(".oMLX-\(r.version)-new.app")
            try? FileManager.default.removeItem(at: staged)
            _ = try await run("/usr/bin/ditto", [newApp.path, staged.path])
            defer { try? FileManager.default.removeItem(at: staged) }
            try await verify(staged)

            status = "Waiting for oMLX to finish its current requests…"
            guard await OMLXAdmin.waitUntilIdle(upstream: upstream, doing: "upgrading", status: { [weak self] s in if let s { self?.status = s } }) else { throw fail("oMLX stayed busy for 15 minutes, so it wasn't upgraded. Try again when it's free") }
            status = "Quitting oMLX… (if oMLX asks, confirm Quit)"
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) { app.terminate() }
            var quit = false
            for _ in 0..<300 {                    // up to 10 minutes for the confirmation
                if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty { quit = true; break }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard quit else { throw fail("oMLX didn't quit, so nothing was changed. Quit it from its menu and try again") }

            status = "Installing oMLX \(r.version)…"
            if FileManager.default.fileExists(atPath: OMLX.appURL.path) {
                try await NSWorkspace.shared.recycle([OMLX.appURL])     // the old version stays in the Trash
            }
            try FileManager.default.moveItem(at: staged, to: OMLX.appURL)   // same folder: an instant rename
            status = "Starting oMLX \(r.version)…"
            NSWorkspace.shared.openApplication(at: OMLX.appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            for _ in 0..<90 {
                if await OMLX.isRunning(upstream: upstream) { break }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            status = await OMLX.isRunning(upstream: upstream)
                ? "oMLX \(Self.installedVersion()) is installed and running. The old version is in the Trash."
                : "oMLX \(Self.installedVersion()) is installed but hasn't started yet. Open it from Applications."
        } catch {
            status = nil
            self.error = error.localizedDescription
        }
    }

    private func fail(_ msg: String) -> NSError {
        NSError(domain: "OMLXUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func download(_ url: URL, size: Int64) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw fail("Download failed") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("oMLX-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func attach(_ dmg: URL) async throws -> String {
        let out = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any],
              let mount = (plist["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first else {
            throw fail("Couldn't open the installer disk image")
        }
        return mount
    }

    /// Notarized, and signed by oMLX's developer.
    private func verify(_ app: URL) async throws {
        _ = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = try await run("/usr/bin/codesign", ["-dv", app.path], stderr: true)
        guard info.contains("TeamIdentifier=\(Self.teamID)") else {
            throw fail("The new oMLX isn't signed by oMLX's developer; nothing was changed")
        }
        _ = try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
    }

    /// Runs a command-line tool off the main thread (copying oMLX.app takes seconds).
    @discardableResult
    private func run(_ tool: String, _ args: [String], stderr: Bool = false) async throws -> String {
        try await Task.detached { try Self.exec(tool, args, stderr: stderr) }.value
    }

    nonisolated private static func exec(_ tool: String, _ args: [String], stderr: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "OMLXUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\((tool as NSString).lastPathComponent) failed: \(String(decoding: e, as: UTF8.self).prefix(300))"])
        }
        return String(decoding: stderr ? e : o, as: UTF8.self)
    }
}
