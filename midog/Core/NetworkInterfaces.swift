import Foundation
import SystemConfiguration

/// 一张物理网卡的快照。
/// bsdName 是 mihomo `interface-name` 真正要用的名字（en0 / en5），
/// displayName 是系统设置里显示的名字（Wi-Fi / iPhone USB），只用于界面展示。
struct NetIface: Equatable, Identifiable {
    enum Kind {
        case wifi
        case usbTether      // iPhone / iPad / Android 的 USB 网络共享
        case ethernet
        case other
    }

    let bsdName: String
    let displayName: String
    let kind: Kind
    /// 当前 IPv4 地址；nil 表示网卡存在但没拿到地址（未激活），此时绑上去必然连不通
    let ipv4: String?

    var id: String { bsdName }
    var active: Bool { ipv4 != nil }
    var label: String { "\(displayName) (\(bsdName))" }
}

/// 网卡枚举。只读系统状态，不做任何修改。
enum NetworkInterfaces {

    /// 全部物理网卡（含未激活的），按 SystemConfiguration 的顺序。
    static func snapshot() -> [NetIface] {
        let ips = ipv4Map()
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        return all.compactMap { iface in
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { return nil }
            let display = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? bsd
            let type = (SCNetworkInterfaceGetInterfaceType(iface) as String?) ?? ""
            return NetIface(bsdName: bsd,
                            displayName: display,
                            kind: classify(display: display, type: type),
                            ipv4: ips[bsd])
        }
    }

    /// Wi-Fi 网卡：类型判定，不依赖名字，稳定。
    static func wifi(in list: [NetIface]) -> NetIface? {
        list.first { $0.kind == .wifi && $0.active } ?? list.first { $0.kind == .wifi }
    }

    /// USB 网络共享网卡。
    /// 首选按名字认出来的 iPhone / iPad / Android；
    /// 认不出来时退一步：取一张已经拿到 IP、又不是雷雳/网桥的以太网卡
    /// （macOS 把 USB 网络共享归为 Ethernet 类型，没有专门的类型可判）。
    static func usbTether(in list: [NetIface]) -> NetIface? {
        if let named = list.first(where: { $0.kind == .usbTether && $0.active }) { return named }
        if let named = list.first(where: { $0.kind == .usbTether }) { return named }
        return list.first {
            $0.kind == .ethernet && $0.active && !isBuiltInBridge($0.displayName)
        }
    }

    /// bsdName → IPv4。link-local(169.254.x) 是自分配地址，等同于没联网，直接丢掉。
    static func ipv4Map() -> [String: String] {
        var out: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard out[name] == nil else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            out[name] = ip
        }
        return out
    }

    /// 单张网卡的当前 IPv4，用于已开启分流后的在线检查。
    static func ipv4(of bsdName: String) -> String? {
        ipv4Map()[bsdName]
    }

    /// bsdName → 网卡累计发送字节数（if_data.ifi_obytes）。
    /// 用来验证"流量确实从这张网卡出去了"：内核里 interface-name 写对了但链路没真用上时，
    /// 这个计数不会涨。注意它是 32 位计数器，会回绕，比较增量必须用 UInt32 的溢出减法。
    static func outBytesMap() -> [String: UInt32] {
        var out: [String: UInt32] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let raw = ptr.pointee.ifa_data else { continue }
            let info = raw.assumingMemoryBound(to: if_data.self).pointee
            out[String(cString: ptr.pointee.ifa_name)] = info.ifi_obytes
        }
        return out
    }

    // ---- 内部 ----

    private static func classify(display: String, type: String) -> NetIface.Kind {
        if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return .wifi }
        let d = display.lowercased()
        if d.contains("iphone") || d.contains("ipad") || d.contains("android")
            || d.contains("rndis") || d.contains("ncm") {
            return .usbTether
        }
        if type == (kSCNetworkInterfaceTypeEthernet as String) { return .ethernet }
        return .other
    }

    /// 雷雳网桥 / 雷雳网口在本机恒定存在，不可能是手机热点，兜底挑选时排除掉
    private static func isBuiltInBridge(_ display: String) -> Bool {
        let d = display.lowercased()
        return d.contains("thunderbolt") || d.contains("bridge") || d.contains("雷雳")
    }
}
