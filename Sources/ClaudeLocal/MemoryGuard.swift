import Foundation
import Darwin

/// Makes room before a model loads. Engines don't know about each other's memory: oMLX can't see
/// what Splash has loaded and vice versa, so a big model on one engine plus a model still loaded on
/// another sends macOS into swap. Before a request needs a model that isn't loaded, this compares
/// its size with free memory and, if it won't fit, frees other engines' models (or refuses).
enum MemoryGuard {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case unload, refuse, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .unload: return "Unload other engines' models"
            case .refuse: return "Refuse with a message"
            case .off: return "Off"
            }
        }
    }

    /// A model loaded in another engine that could be freed.
    struct Holder: Equatable {
        let engine: EngineKind
        let model: String
        let bytes: Int64       // 0 when unknown
        let busy: Bool         // serving a request now, or used in the last couple of minutes
    }

    enum Decision: Equatable {
        case go
        case free([Holder])
        case refuse(String)
    }

    /// Left free on top of the model itself: the KV cache, the app, macOS.
    static let headroom: Int64 = 4 << 30

    /// What to do. Frees the fewest idle models (biggest first) that make room. A busy model is never
    /// cut off mid-request: if only freeing it would make room, the request is refused instead.
    static func decide(target: String, need: Int64, available: Int64, holders: [Holder], mode: Mode) -> Decision {
        guard mode != .off, need > 0, need + headroom > available, !holders.isEmpty else { return .go }
        let idle = holders.filter { !$0.busy }
        var chosen: [Holder] = []
        var room = available
        for h in idle.sorted(by: { $0.bytes > $1.bytes }) where room < need + headroom {
            chosen.append(h)
            room += h.bytes
        }
        let head = "Not enough memory for \(target): it needs about \(gb(need)) and \(gb(available)) is free."
        if room < need + headroom {
            // Idle models aren't enough: a busy one would have to go, so wait for it.
            if let b = holders.first(where: \.busy) {
                return .refuse("\(head) \(b.model) in \(b.engine.label) is busy or was used in the last 2 minutes, so it wasn't unloaded. Unload it yourself, or try again when it's idle.")
            }
            chosen = idle       // sizes unknown (0), or not enough even with everything freed: free all and try
        }
        if chosen.isEmpty { return .go }
        if mode == .refuse {
            let what = chosen.map { "\($0.model) (\($0.engine.label)\($0.bytes > 0 ? ", \(gb($0.bytes))" : ""))" }
                .joined(separator: ", ")
            return .refuse("\(head) Unload \(what) first, or set LLM Switcher > Engines > Memory guard to unload them for you.")
        }
        return .free(chosen)
    }

    /// Memory that can be given to a model now: all of it minus wired, active and compressed pages
    /// (the same split oMLX's panel and the System tab use).
    static func availableBytes() -> Int64 {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard rc == KERN_SUCCESS else { return total }
        let page = Int64(vm_kernel_page_size)
        let used = (Int64(stats.wire_count) + Int64(stats.active_count) + Int64(stats.compressor_page_count)) * page
        return max(0, total - used)
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.0f GB", Double(bytes) / 1_073_741_824) }
}
