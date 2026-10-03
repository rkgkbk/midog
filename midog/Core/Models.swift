import Foundation

// ============ 默认值（与旧版 config-generator.js 保持一致） ============

enum Defaults {
    /// 历史版本的默认 nameserver；仅用于识别并迁移未自定义过的配置。
    static let legacyNameservers: [JSONValue] = [
        // 旧版本把国内 DoH 当作业务 DNS
        .array([
            .string("https://223.5.5.5/dns-query"),
            .string("https://doh.pub/dns-query")
        ]),
        // 上一版走代理的普通 DoH（无恶意站点过滤）
        .array([
            .string("https://1.1.1.1/dns-query#PROXY"),
            .string("https://8.8.8.8/dns-query#PROXY")
        ])
    ]

    static let settings: [String: JSONValue] = [
        // 端口：mixed-port 同时提供 HTTP/SOCKS；port / socks-port 为 0 表示不单独开
        "mixed-port": .number(7891),
        "port": .number(0),
        "socks-port": .number(0),
        "allow-lan": .bool(false),
        "bind-address": .string("*"),          // allow-lan 打开时的监听地址
        "mode": .string("rule"),
        "log-level": .string("error"),
        "external-controller": .string("127.0.0.1:9090"),
        "secret": .string(""),
        "ipv6": .bool(false),
        "unified-delay": .bool(true),
        "tcp-concurrent": .bool(true),
        "find-process-mode": .string("strict"), // 进程匹配：strict / always / off
        "global-client-fingerprint": .string("chrome"), // TLS 指纹伪装（vmess/vless/trojan 等生效）
        "keep-alive-interval": .number(30),
        "keep-alive-idle": .number(600)
    ]

    static let dns: [String: JSONValue] = [
        "enable": .bool(true),
        "listen": .string("127.0.0.1:9053"),
        "ipv6": .bool(false),
        "respect-rules": .bool(false),
        "enhanced-mode": .string("fake-ip"),
        "fake-ip-range": .string("198.18.0.1/16"),
        "fake-ip-filter": .array([
            .string("*.lan"), .string("*.local"),
            .string("+.msftconnecttest.com"), .string("+.msftncsi.com"),
            .string("time.*.com"), .string("ntp.*.com"), .string("+.pool.ntp.org"),
            .string("localhost.ptlogin2.qq.com")
        ]),
        // 只负责 DNS 服务和代理节点域名的引导解析，避免代理尚未建立时产生循环依赖。
        "default-nameserver": .array([.string("223.5.5.5"), .string("119.29.29.29")]),
        "proxy-server-nameserver": .array([
            .string("https://223.5.5.5/dns-query"),
            .string("https://doh.pub/dns-query")
        ]),
        // DIRECT 出口使用国内 DNS，避免直连域名仍通过代理侧的境外 DNS 解析。
        "direct-nameserver": .array([
            .string("https://223.5.5.5/dns-query"),
            .string("https://doh.pub/dns-query")
        ]),
        // 普通域名查询固定经 PROXY 访问境外 DoH，避免运营商/国内公共 DNS 泄漏。
        // 使用 Cloudflare for Families（1.1.1.3 / 1.0.0.3），在解析层拦截恶意站点与成人内容。
        "nameserver": .array([
            .string("https://1.1.1.3/dns-query#PROXY"),
            .string("https://1.0.0.3/dns-query#PROXY")
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

/// 允许写进生成配置的基础设置项。其余顶层 key（listeners、sub-rules、tunnels 等）
/// 可以开出不经过 rules 的入站，一律丢弃。
let ALLOWED_SETTINGS_KEYS = Set(Defaults.settings.keys)

let FINAL_TARGETS = ["PROXY", "AUTO", "DIRECT", "REJECT"]
let RULE_BEHAVIORS = ["classical", "domain", "ipcidr"]
let RULE_FORMATS = ["yaml", "text", "mrs"]
let RULE_TARGET_KINDS = ["builtin", "group", "node"]

/// 内置强制规则集：不存进 data.json，由 ConfigGenerator 每次生成时无条件写入，
/// 因此在 App 界面里无法关闭/删除，手改 data.json 也不会生效——只能改代码重新编译。
/// 对应规则在 rules 里排在所有用户规则之前，用户规则无法把它挡掉。
struct MandatoryRuleProvider: Identifiable {
    let provider: RuleProvider
    /// App bundle 内的兜底副本：缓存文件缺失（首次运行 / 被手动删掉）时复制过去，
    /// 避免下载失败时规则集为空导致放行。
    let bundledResource: String
    let bundledExtension: String
    /// 内核加载后规则条数低于此值就认为缓存被替换/损坏，用兜底副本覆盖并重载。
    /// 取上游列表当前条数（约 6500）的一半，留足上游自然缩水的余量。
    let minimumRuleCount: Int
    /// 兜底副本自身的预期 SHA-256。App 包内的资源被换成空表时，兜底就成了帮凶，
    /// 因此复制之前先验一次哈希；不匹配宁可不恢复，也不把假规则写进缓存。
    /// 换上游文件时必须同步更新这里：shasum -a 256 midog/Resources/<file>
    let bundledSHA256: String

    var id: String { provider.name }

    var bundledURL: URL? {
        Bundle.main.url(forResource: bundledResource, withExtension: bundledExtension)
    }
}

let MANDATORY_RULE_PROVIDERS: [MandatoryRuleProvider] = [
    MandatoryRuleProvider(
        provider: RuleProvider(
            name: "__MIDOG_ADULT_BLOCK",
            url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-porn.list",
            behavior: "domain",
            // 用 text 而不是 mrs：mihomo 对 mrs 规则集的 ruleCount 恒为 0，
            // 条数校验（Store.enforceMandatoryRuleProviders）就失去了信号。
            format: "text",
            // converted = type: file：只读 App 维护的、与包内副本哈希一致的缓存，不回源下载
            converted: true,
            sourceFormat: nil,
            target: "REJECT",
            interval: 86400,
            viaProxy: true,   // GitHub 直连可能失败，固定走代理下载
            enabled: true
        ),
        bundledResource: "category-porn",
        bundledExtension: "list",
        minimumRuleCount: 3000,
        bundledSHA256: "c9504ff281807e51adc904bda2dd18befa9d5e40765a5671a957cc891336962d"
    )
]

/// 出站模式锁定为 rule：global / direct 会让 rules 整段失效，内置强制规则也就跟着失效。
let LOCKED_MODE = "rule"

let HEALTH_CHECK_URL = "http://www.gstatic.com/generate_204"

/// 生成 external-controller 的默认认证密钥。
/// secret 留空时 mihomo 的 REST API 不做任何认证，本机任何进程（包括网页里的 fetch）
/// 都能直接打 127.0.0.1:9090，比如 PATCH /configs 把出站模式改成 global 绕过锁定；
/// 因此每套 data.json 首次生成时都必须带一个随机密钥，而不是让用户来选。
/// SystemRandomNumberGenerator 在 Darwin 上由内核 CSPRNG (arc4random) 提供，适合生成密钥。
func generateControllerSecret() -> String {
    var rng = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 0, count: 24)
    for i in bytes.indices { bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// RULE-SET 的目标可以是内置策略、策略组或具体节点。
/// 逗号和换行会破坏 mihomo 的 `RULE-SET,name,target` 语法，因此不接受。
func normalizedRuleTarget(_ value: String) -> String? {
    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty,
          !target.contains(","),
          !target.contains("\n"),
          !target.contains("\r") else { return nil }
    return target
}

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
    var targetKind: String       // builtin / group / node
    var interval: Int
    var viaProxy: Bool
    var enabled: Bool
    var convertedUpdatedAt: String?   // 转换型规则集最近一次拉取上游的时间

    var id: String { name }
    var isLocal: Bool { url.hasPrefix("local://") }

    var sourceDisplayText: String {
        isLocal ? "本地 · \(String(url.dropFirst("local://".count)))" : url
    }

    var fileExtension: String {
        format == "mrs" ? ".mrs" : (format == "text" ? ".txt" : ".yaml")
    }

    init(name: String, url: String, behavior: String, format: String, converted: Bool,
         sourceFormat: String?, target: String, targetKind: String = "builtin",
         interval: Int, viaProxy: Bool, enabled: Bool,
         convertedUpdatedAt: String? = nil) {
        self.name = name
        self.url = url
        self.behavior = behavior
        self.format = format
        self.converted = converted
        self.sourceFormat = sourceFormat
        self.target = target
        self.targetKind = RULE_TARGET_KINDS.contains(targetKind) ? targetKind : "builtin"
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
        let decodedKind = try? c.decode(String.self, forKey: .targetKind)
        targetKind = decodedKind.flatMap { RULE_TARGET_KINDS.contains($0) ? $0 : nil }
            ?? (FINAL_TARGETS.contains(target) ? "builtin" : "group")
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

    init() {
        settings["secret"] = .string(generateControllerSecret())
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = 2
        let rawSettings = (try? c.decode([String: JSONValue].self, forKey: .settings)) ?? [:]
        settings = Defaults.settings.merging(rawSettings) { _, new in new }
        settings["mode"] = .string(LOCKED_MODE) // 手改 data.json 也改不动出站模式
        // secret 缺失/为空（全新安装，或升级自没有认证的旧版本）时补一个随机密钥，
        // 绝不把 external-controller 落回无认证状态。
        if (settings["secret"]?.stringValue ?? "").isEmpty {
            settings["secret"] = .string(generateControllerSecret())
        }
        let rawDns = (try? c.decode([String: JSONValue].self, forKey: .dns)) ?? [:]
        dns = Defaults.dns.merging(rawDns) { _, new in new }
        // 升级旧版默认 DNS；用户自行填写的 nameserver 保持不变。
        if let ns = rawDns["nameserver"], Defaults.legacyNameservers.contains(ns) {
            dns["nameserver"] = Defaults.dns["nameserver"]
        }
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
    /// 恒为 LOCKED_MODE：写入被忽略，读出也不受 data.json 里的值影响。
    var mode: String {
        get { LOCKED_MODE }
        set { settings["mode"] = .string(LOCKED_MODE) }
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
