import Foundation
import SystemConfiguration

struct LANAddress: Hashable, Identifiable {
    let interface: String
    let ip: String
    var id: String { ip }

    /// Tailscale hands out 100.64.0.0/10 addresses on a utun interface.
    var isTailscale: Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return interface.hasPrefix("utun") && p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }

    var label: String {
        if isTailscale { return "Tailscale (works away from home)" }
        if interface.hasPrefix("en") { return "Home network" }
        if interface.hasPrefix("bridge") || interface.hasPrefix("vnic") { return "Virtual machines" }
        return "Other (\(interface))"
    }
}

/// This Mac's addresses that other devices can reach.
enum LAN {
    /// Private IPv4 addresses on active interfaces: home network first, then Tailscale, then others.
    static func lanAddresses() -> [LANAddress] {
        var result: [LANAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if Gateway.isPrivate(ip) && !ip.hasPrefix("169.254.") {
                result.append(LANAddress(interface: String(cString: ifa.ifa_name), ip: ip))
            }
        }
        func rank(_ a: LANAddress) -> Int { a.interface.hasPrefix("en") ? 0 : (a.isTailscale ? 1 : 2) }
        return result.sorted { (rank($0), $0.interface) < (rank($1), $1.interface) }
    }

    /// Bonjour name, e.g. "Office-Mac.local".
    static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { return name + ".local" }
        return ProcessInfo.processInfo.hostName
    }

    /// Friendly computer name, e.g. "Office Mac".
    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
