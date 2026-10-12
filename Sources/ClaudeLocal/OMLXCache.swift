import AppKit
import Foundation

/// oMLX's prompt cache on the SSD (~/.omlx/cache). Each block file names the model it belongs to in
/// its safetensors header; hybrid models also keep "sidecar" folders named after a block. This
/// reads those headers to size the cache per model and to remove one model's share of it.
enum OMLXCache {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omlx/cache", isDirectory: true)

    struct Entry: Identifiable, Equatable {
        var id: String { model }
        let model: String
        var bytes: Int64
        var files: Int
    }

    /// Model named in a block file's header, read without loading the tensors.
    private static func modelName(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let lenData = try? h.read(upToCount: 8), lenData.count == 8 else { return nil }
        let len = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard len > 0, len < 10_000_000, let head = try? h.read(upToCount: Int(len)),
              let obj = try? JSONSerialization.jsonObject(with: head) as? [String: Any],
              let meta = obj["__metadata__"] as? [String: Any] else { return nil }
        return meta["model_name"] as? String
    }

    private static func blockFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for sub in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where sub.count == 1 {
            let d = dir.appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".safetensors") {
                out.append(d.appendingPathComponent(f))
            }
        }
        return out
    }

    private static func size(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        } else {
            total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Cache use per model, biggest first. Runs off the main thread (reads ~2,000 small headers).
    static func usage() async -> [Entry] {
        await Task.detached(priority: .utility) {
            var byModel: [String: Entry] = [:]
            var blockOwner: [String: String] = [:]
            for f in blockFiles() {
                let m = modelName(f) ?? "Unknown"
                blockOwner[f.deletingPathExtension().lastPathComponent] = m
                let s = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                byModel[m, default: Entry(model: m, bytes: 0, files: 0)].bytes += s
                byModel[m]?.files += 1
            }
            let side = dir.appendingPathComponent("_gdn_sidecars")
            for d in (try? FileManager.default.contentsOfDirectory(atPath: side.path)) ?? [] {
                let m = blockOwner[d] ?? "Unknown"
                byModel[m, default: Entry(model: m, bytes: 0, files: 0)].bytes += size(side.appendingPathComponent(d))
            }
            return byModel.values.sorted { $0.bytes > $1.bytes }
        }.value
    }

    /// Moves one model's cache files to the Trash (one folder, so it's easy to restore).
    /// Returns the bytes moved.
    @discardableResult
    static func trash(model: String) async throws -> Int64 {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let staging = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".omlx/cache-removed-\(model.replacingOccurrences(of: "/", with: "_"))-\(stamp)", isDirectory: true)
        var moved: Int64 = 0
        var hashes = Set<String>()
        var failure: Error?
        do {
            for f in blockFiles() where modelName(f) == model {
                let dest = staging.appendingPathComponent("blocks").appendingPathComponent(f.deletingLastPathComponent().lastPathComponent)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                let s = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                hashes.insert(f.deletingPathExtension().lastPathComponent)
                try fm.moveItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
                moved += s
            }
            let side = dir.appendingPathComponent("_gdn_sidecars")
            for d in (try? fm.contentsOfDirectory(atPath: side.path)) ?? [] where hashes.contains(d) {
                let src = side.appendingPathComponent(d)
                let s = size(src)
                try fm.createDirectory(at: staging.appendingPathComponent("sidecars"), withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: staging.appendingPathComponent("sidecars").appendingPathComponent(d))
                moved += s
            }
        } catch { failure = error }
        // Whatever was moved goes to the Trash as one folder, even if a later move failed.
        if fm.fileExists(atPath: staging.path) {
            try await NSWorkspace.shared.recycle([staging])
        }
        if let failure { throw failure }
        return moved
    }
}
