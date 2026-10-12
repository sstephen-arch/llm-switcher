import Darwin
import Foundation
import IOKit

/// Live system stats, read the same way oMLX's System Stats panel does: Mach host statistics,
/// the IOKit registry (GPU), sysctl, and the thermal state. All public API, no helper processes.
struct SystemSample {
    var coreGroups: [(name: String, usage: Double)] = []   // e.g. ("Performance", 0.15), ("Super", 0.08)
    var gpu: Double?                                        // 0…1
    var gpuMemory: Int64?                                   // bytes in use by the GPU
    var wired: Int64 = 0, active: Int64 = 0, compressed: Int64 = 0, free: Int64 = 0, total: Int64 = 0
    var load: (Double, Double, Double) = (0, 0, 0)
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0

    var used: Int64 { wired + active + compressed }
}

/// oMLX's own serving stats (from its admin API). The response also carries oMLX's master key; it is
/// dropped immediately and never stored or shown.
struct ServingStats {
    var requests = 0
    var promptTokens = 0
    var completionTokens = 0
    var cacheEfficiency: Double = 0
    var avgPrefill: Double = 0
    var avgGeneration: Double = 0
    var activeRequests = 0
    var waitingRequests = 0
    var modelMemoryUsed: Int64 = 0
    var modelMemoryMax: Int64 = 0
    var loaded: [(id: String, size: Int64, active: Int, idle: Double)] = []
}

final class SystemSampler {
    private var lastTicks: [[UInt32]] = []
    private lazy var groups: [(name: String, cpus: Range<Int>)] = Self.coreLayout()

    /// Core groups in logical-CPU order: lower performance levels come first on Apple silicon
    /// (oMLX uses the same contiguous assumption, which holds for every non-Ultra chip).
    static func coreLayout() -> [(name: String, cpus: Range<Int>)] {
        let levels = sysctlInt("hw.nperflevels") ?? 1
        var out: [(String, Range<Int>)] = []
        var start = 0
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let n = sysctlInt("hw.perflevel\(level).logicalcpu") ?? 0
            let name = sysctlString("hw.perflevel\(level).name") ?? (level == 0 ? "Performance" : "Efficiency")
            out.append(("\(name) cores", start..<(start + n)))
            start += n
        }
        return out
    }

    func sample() -> SystemSample {
        var s = SystemSample()
        s.coreGroups = cpuUsage()
        (s.gpu, s.gpuMemory) = gpuStats()
        memory(&s)
        var avg = [Double](repeating: 0, count: 3)
        if getloadavg(&avg, 3) == 3 { s.load = (avg[0], avg[1], avg[2]) }
        s.thermal = ProcessInfo.processInfo.thermalState
        s.uptime = ProcessInfo.processInfo.systemUptime
        return s
    }

    private func cpuUsage() -> [(name: String, usage: Double)] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var ticks: [[UInt32]] = []
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return groups.map { ($0.name, 0) } }
        func busy(_ cpus: Range<Int>) -> Double {
            var used: UInt64 = 0, all: UInt64 = 0
            for c in cpus where c < ticks.count {
                let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(ticks[c][$0] &- lastTicks[c][$0]) }
                let idle = d[Int(CPU_STATE_IDLE)]
                let sum = d.reduce(0, +)
                used += sum - idle; all += sum
            }
            return all > 0 ? Double(used) / Double(all) : 0
        }
        return groups.map { ($0.name, busy($0.cpus)) }
    }

    /// IOAccelerator "PerformanceStatistics": Device Utilization % and In use system memory.
    private func gpuStats() -> (Double?, Int64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(iterator) }
        var util: Double?, mem: Int64?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let props = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                if let u = props["Device Utilization %"] as? NSNumber { util = max(util ?? 0, u.doubleValue / 100) }
                if let m = props["In use system memory"] as? NSNumber { mem = (mem ?? 0) + m.int64Value }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return (util, mem)
    }

    private func memory(_ s: inout SystemSample) {
        s.total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard rc == KERN_SUCCESS else { return }
        let page = Int64(vm_kernel_page_size)
        s.wired = Int64(stats.wire_count) * page
        s.active = Int64(stats.active_count) * page
        s.compressed = Int64(stats.compressor_page_count) * page
        s.free = max(0, s.total - s.wired - s.active - s.compressed)   // same split as oMLX's panel
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        return sysctlbyname(name, &buf, &size, nil, 0) == 0 ? String(cString: buf) : nil
    }
}

extension OMLX {
    /// oMLX's serving stats via its admin API (session login with the key, cookie-based).
    static func servingStats(upstream: String) async -> ServingStats? {
        guard let login = URL(string: upstream + "/admin/api/login"),
              let statsURL = URL(string: upstream + "/admin/api/stats?scope=session") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: login, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": apiKey()])
        guard let (_, r1) = try? await session.data(for: req), (r1 as? HTTPURLResponse)?.statusCode == 200,
              let (data, r2) = try? await session.data(from: statsURL), (r2 as? HTTPURLResponse)?.statusCode == 200,
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        obj.removeValue(forKey: "api_key")       // never keep oMLX's master key
        var s = ServingStats()
        s.requests = obj["total_requests"] as? Int ?? 0
        s.promptTokens = obj["total_prompt_tokens"] as? Int ?? 0
        s.completionTokens = obj["total_completion_tokens"] as? Int ?? 0
        s.cacheEfficiency = (obj["cache_efficiency"] as? NSNumber)?.doubleValue ?? 0
        s.avgPrefill = (obj["avg_prefill_tps"] as? NSNumber)?.doubleValue ?? 0
        s.avgGeneration = (obj["avg_generation_tps"] as? NSNumber)?.doubleValue ?? 0
        if let a = obj["active_models"] as? [String: Any] {
            s.activeRequests = a["total_active_requests"] as? Int ?? 0
            s.waitingRequests = a["total_waiting_requests"] as? Int ?? 0
            s.modelMemoryUsed = (a["model_memory_used"] as? NSNumber)?.int64Value ?? 0
            s.modelMemoryMax = (a["model_memory_max"] as? NSNumber)?.int64Value ?? 0
            for m in a["models"] as? [[String: Any]] ?? [] {
                s.loaded.append((m["id"] as? String ?? "?", (m["actual_size"] as? NSNumber)?.int64Value ?? 0,
                                 m["active_requests"] as? Int ?? 0, (m["idle_seconds"] as? NSNumber)?.doubleValue ?? 0))
            }
        }
        return s
    }
}
