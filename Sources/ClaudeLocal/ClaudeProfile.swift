import AppKit
import Foundation

/// Switches Claude Desktop between LLM Switcher (oMLX) mode and the normal Claude cloud.
///
/// Same steps as Ollama 0.40's cmd/launch/claude_desktop.go:
///   apply:   write our gateway profile + _meta entry, set deploymentMode=3p in BOTH config files,
///            quit Claude, wait, write them again (Claude saves its settings while quitting and would
///            undo ours), reopen Claude.
///   restore: deploymentMode=1p in both, remove our _meta entry, reopen.
/// Each file is backed up once per day before its first change (*.claude-local-bak-YYYYMMDD).
enum ClaudeProfile {
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let profileID = "00000000-0000-4000-8000-000000000215"   // Ollama used …0114
    static let profileName = "LLM Switcher (local)"
    static let ollamaProfileID = "00000000-0000-4000-8000-000000000114"

    private static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    static let normalConfig = support.appendingPathComponent("Claude/claude_desktop_config.json")
    static let thirdPartyConfig = support.appendingPathComponent("Claude-3p/claude_desktop_config.json")
    static let meta = support.appendingPathComponent("Claude-3p/configLibrary/_meta.json")
    static let profile = support.appendingPathComponent("Claude-3p/configLibrary/\(profileID).json")

    enum Mode: Equatable {
        case cloud, claudeLocal, other(String)
        var label: String {
            switch self {
            case .cloud: return "Claude cloud"
            case .claudeLocal: return "Local models"
            case .other(let s): return s
            }
        }
    }

    // MARK: status

    static func currentMode() -> Mode {
        guard (read(normalConfig)["deploymentMode"] as? String) == "3p" else { return .cloud }
        switch read(meta)["appliedId"] as? String {
        case profileID: return .claudeLocal
        case ollamaProfileID: return .other("Ollama")
        case let id?: return .other("Other gateway (\(id.suffix(4)))")
        case nil: return .other("Third-party (no profile)")
        }
    }

    static var claudeIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty
    }

    // MARK: switching

    static func applyFiles(port: Int, autoMode: Bool) throws {
        var p = read(profile)
        p["inferenceProvider"] = "gateway"
        p["inferenceGatewayBaseUrl"] = "http://127.0.0.1:\(port)"
        // Claude needs some key; the gateway ignores it and adds oMLX's own key itself.
        p["inferenceGatewayApiKey"] = "claude-local"
        p["inferenceGatewayAuthScheme"] = "bearer"
        p["deploymentDisplayName"] = profileName
        p["chatTabEnabled"] = true
        p["disableDeploymentModeChooser"] = true
        p["coworkEgressAllowedHosts"] = ["*"]
        p["disableEssentialTelemetry"] = true
        p["disableNonessentialTelemetry"] = true
        // Off by default: in local mode Claude's safety check runs on the same busy local model and
        // times out (a 9 Oct 2026 session lost minutes to this).
        p["autoModeEnabled"] = autoMode
        p["inferenceStreamIdleTimeoutSec"] = 1800
        p.removeValue(forKey: "inferenceModels")
        try write(profile, p)
        try writeMeta(applied: true)
        try setMode(thirdPartyConfig, "3p")
        try setMode(normalConfig, "3p")
    }

    static func restoreFiles() throws {
        try setMode(normalConfig, "1p")
        try setMode(thirdPartyConfig, "1p")
        try writeMeta(applied: false)
    }

    /// Quit Claude (if open), re-apply `reapply` after it has exited, then open it again.
    static func restartClaude(reapply: () throws -> Void) async throws {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID) {
            app.terminate()
        }
        for _ in 0..<150 where claudeIsRunning {          // up to 30 s
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if claudeIsRunning { throw SwitchError.claudeWouldNotQuit }
        try reapply()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else {
            throw SwitchError.claudeNotInstalled
        }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    enum SwitchError: LocalizedError {
        case claudeWouldNotQuit, claudeNotInstalled
        var errorDescription: String? {
            switch self {
            case .claudeWouldNotQuit: return "Claude didn't quit. Quit it yourself and try again."
            case .claudeNotInstalled: return "Claude Desktop isn't installed."
            }
        }
    }

    // MARK: file helpers

    private static func writeMeta(applied: Bool) throws {
        var m = read(meta)
        var entries = (m["entries"] as? [Any] ?? []).filter { ($0 as? [String: Any])?["id"] as? String != profileID }
        if applied {
            entries.append(["id": profileID, "name": profileName])
            m["appliedId"] = profileID
        } else if m["appliedId"] as? String == profileID {
            m.removeValue(forKey: "appliedId")
        }
        m["entries"] = entries
        try write(meta, m)
    }

    private static func setMode(_ url: URL, _ mode: String) throws {
        var c = read(url)
        c["deploymentMode"] = mode
        try write(url, c)
    }

    static func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static let dayStamp: String = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
    }()

    private static func write(_ url: URL, _ obj: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = URL(fileURLWithPath: url.path + ".claude-local-bak-\(dayStamp)")
        if fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
