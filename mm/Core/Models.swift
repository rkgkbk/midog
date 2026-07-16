import Foundation

// ============ 默认值（与旧版 config-generator.js 保持一致） ============

enum Defaults {
    static let settings: [String: JSONValue] = [
        "mixed-port": .number(7891),
        "allow-lan": .bool(false),
        "mode": .string("rule"),
        "log-level": .string("error"),
        "external-controller": .string("127.0.0.1:9090"),
        "secret": .string(""),
        "ipv6": .bool(false),
        "unified-delay": .bool(true),
        "tcp-concurrent": .bool(true)
    ]

    static let dns: [String: JSONValue] = [
        "enable": .bool(true),
        "listen": .string("127.0.0.1:9053"),
        "ipv6": .bool(false),
        "enhanced-mode": .string("fake-ip"),
        "fake-ip-range": .string("198.18.0.1/16"),
        "fake-ip-filter": .array([
            .string("*.lan"), .string("*.local"),
            .string("+.msftconnecttest.com"), .string("+.msftncsi.com"),
            .string("time.*.com"), .string("ntp.*.com"), .string("+.pool.ntp.org"),
            .string("localhost.ptlogin2.qq.com")
        ]),
        "default-nameserver": .array([.string("223.5.5.5"), .string("119.29.29.29")]),
        "nameserver": .array([
            .string("https://223.5.5.5/dns-query"),
            .string("https://doh.pub/dns-query")
        ])
    ]

    static let tun: [String: JSONValue] = [
        "enable": .bool(false),
        "stack": .string("mixed"),
        "auto-route": .bool(true),
        "auto-detect-interface": .bool(true),
        "dns-hijack": .array([.string("any:53")]),
        "strict-route": .bool(false)
    ]

    static let rules = [
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "DOMAIN-SUFFIX,local,DIRECT",
        "DOMAIN-SUFFIX,lan,DIRECT",
        "DOMAIN-SUFFIX,cn,DIRECT"
    ]

    static let rulesFileHeader = [
        "# 分流规则：每行一条，# 开头为注释，仅 RULE 模式下生效",
        "# 兜底 (MATCH) 目标在设置中选择"
    ]
}

let FINAL_TARGETS = ["PROXY", "AUTO", "DIRECT", "REJECT"]
let RULE_BEHAVIORS = ["classical", "domain", "ipcidr"]
let RULE_FORMATS = ["yaml", "text", "mrs"]
let HEALTH_CHECK_URL = "http://www.gstatic.com/generate_204"

// ============ 数据模型（与旧版 data.json v2 结构兼容） ============

struct Source: Codable, Identifiable, Equatable {
    var name: String            // configs 目录内的文件名
    var displayName: String
    var url: String?            // nil = 本地导入
    var format: String?
    var updatedAt: String?
    var enabled: Bool

    var id: String { name }
    var isSubscription: Bool { url != nil && !(url ?? "").isEmpty }

    init(name: String, displayName: String, url: String?, format: String?, updatedAt: String?, enabled: Bool) {
        self.name = name
        self.displayName = displayName
        self.url = url
        self.format = format
        self.updatedAt = updatedAt
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? name
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
    }
}

struct RuleProvider: Codable, Identifiable, Equatable {
    var name: String
    var url: String
    var behavior: String        // classical / domain / ipcidr
    var format: String          // yaml / text / mrs
    var converted: Bool         // true = mihomo 不认原始内容，由 App 下载转换为本地 file provider
    var sourceFormat: String?
    var target: String
    var interval: Int
    var viaProxy: Bool
    var enabled: Bool
    var convertedUpdatedAt: String?   // 转换型规则集最近一次拉取上游的时间

    var id: String { name }

    var fileExtension: String {
        format == "mrs" ? ".mrs" : (format == "text" ? ".txt" : ".yaml")
    }

    init(name: String, url: String, behavior: String, format: String, converted: Bool,
         sourceFormat: String?, target: String, interval: Int, viaProxy: Bool, enabled: Bool,
         convertedUpdatedAt: String? = nil) {
        self.name = name
        self.url = url
        self.behavior = behavior
        self.format = format
        self.converted = converted
        self.sourceFormat = sourceFormat
        self.target = target
        self.interval = interval
        self.viaProxy = viaProxy
        self.enabled = enabled
        self.convertedUpdatedAt = convertedUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        behavior = (try? c.decode(String.self, forKey: .behavior)) ?? "classical"
        format = (try? c.decode(String.self, forKey: .format)) ?? "yaml"
        converted = (try? c.decode(Bool.self, forKey: .converted)) ?? false
        sourceFormat = try? c.decodeIfPresent(String.self, forKey: .sourceFormat)
        target = (try? c.decode(String.self, forKey: .target)) ?? "PROXY"
        interval = (try? c.decode(Int.self, forKey: .interval)) ?? 86400
        viaProxy = (try? c.decode(Bool.self, forKey: .viaProxy)) ?? false
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        convertedUpdatedAt = try? c.decodeIfPresent(String.self, forKey: .convertedUpdatedAt)
    }
}

struct AppData: Codable {
    var version: Int = 2
    var settings: [String: JSONValue] = Defaults.settings
    var dns: [String: JSONValue] = Defaults.dns
    var hosts: [String: JSONValue] = [:]
    var tun: [String: JSONValue] = Defaults.tun
    var sources: [Source] = []
    var ruleProviders: [RuleProvider] = []
    var finalTarget: String = "PROXY"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = 2
        let rawSettings = (try? c.decode([String: JSONValue].self, forKey: .settings)) ?? [:]
        settings = Defaults.settings.merging(rawSettings) { _, new in new }
        let rawDns = (try? c.decode([String: JSONValue].self, forKey: .dns)) ?? [:]
        dns = Defaults.dns.merging(rawDns) { _, new in new }
        hosts = (try? c.decode([String: JSONValue].self, forKey: .hosts)) ?? [:]
        let rawTun = (try? c.decode([String: JSONValue].self, forKey: .tun)) ?? [:]
        tun = Defaults.tun.merging(rawTun) { _, new in new }
        sources = (try? c.decode([Source].self, forKey: .sources)) ?? []
        ruleProviders = ((try? c.decode([RuleProvider].self, forKey: .ruleProviders)) ?? [])
            .filter { !$0.name.isEmpty && !$0.url.isEmpty }
        let ft = (try? c.decode(String.self, forKey: .finalTarget)) ?? "PROXY"
        finalTarget = FINAL_TARGETS.contains(ft) ? ft : "PROXY"
    }

    // ---- 常用访问 ----
    var mode: String {
        get { settings["mode"]?.stringValue?.lowercased() ?? "rule" }
        set { settings["mode"] = .string(newValue) }
    }

    var externalController: String {
        settings["external-controller"]?.stringValue ?? "127.0.0.1:9090"
    }

    var secret: String {
        settings["secret"]?.stringValue ?? ""
    }

    var tunEnabled: Bool {
        get { tun["enable"]?.boolValue ?? false }
        set { tun["enable"] = .bool(newValue) }
    }

    /// configs 目录里存在但 sources 未登记的 yaml 文件，补录为本地来源
    mutating func syncLocalFiles(configsDir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: configsDir.path) else { return }
        let known = Set(sources.map { $0.name })
        for f in files.sorted() {
            let lower = f.lowercased()
            guard lower.hasSuffix(".yaml") || lower.hasSuffix(".yml"), !known.contains(f) else { continue }
            sources.append(Source(name: f, displayName: f, url: nil, format: "local", updatedAt: nil, enabled: false))
        }
    }
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}
