import Darwin
import Foundation

/// Addresses the remote control server may listen on.
public enum RemoteNetworkAddresses {
    public static let loopback = "127.0.0.1"

    /// Loopback plus the Mac's Tailscale addresses. Never a wildcard.
    public static func bindable() -> [String] {
        [loopback] + tailscale()
    }

    /// The Mac's addresses in Tailscale's ranges: 100.64.0.0/10 and
    /// fd7a:115c:a1e0::/48.
    public static func tailscale() -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let bytes = withUnsafeBytes(of: addr) { Array($0) }
                if isTailscaleV4(bytes), let s = numeric(sa) { out.append(s) }
            case AF_INET6:
                let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                    withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
                }
                if isTailscaleV6(bytes), let s = numeric(sa) { out.append(s) }
            default:
                break
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func isTailscaleV4(_ b: [UInt8]) -> Bool {
        b.count == 4 && b[0] == 100 && (b[1] & 0xC0) == 64
    }

    static func isTailscaleV6(_ b: [UInt8]) -> Bool {
        b.count == 16 && b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
    }

    private static func numeric(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_len)
        guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let s = String(cString: host)
        // Drop a zone suffix, Tailscale addresses are global.
        return s.split(separator: "%").first.map(String.init)
    }
}
