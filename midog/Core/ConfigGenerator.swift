import Foundation
import CryptoKit

/// 主配置生成器（移植自旧版 config-generator.js）：
/// - 订阅/本地配置作为 proxy-providers (type: file) 引用，节点与主配置解耦
/// - YAML 采用 "key: <JSON>" 形式输出（YAML 1.2 是 JSON 的超集），避免手写 YAML 序列化
/// - 转换型规则集（base64/gfwlist）由 App 下载转换后写入本地文件，以 type: file 引用
///   —— 旧版需要 Node 服务常驻提供 HTTP 回源，这里去掉了这层依赖
enum ConfigGenerator {

    /// 内置规则集的缓存文件与 App 包内副本的哈希不一致（被删、被换、被改）时，用包内副本覆盖。
    /// 规则集以 type: file 引用这份缓存，不再回源下载，所以缓存内容必须与包内副本逐字节一致。
    static func seedMandatoryCaches(into ruleProvidersDir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: ruleProvidersDir, withIntermediateDirectories: true)
        for item in MANDATORY_RULE_PROVIDERS {
            let cache = ruleProvidersDir.appendingPathComponent(item.provider.name + item.provider.fileExtension)
            if sha256(of: cache) == item.bundledSHA256 { continue }
            restoreBundledCache(item, to: cache)
        }
    }

    /// 用兜底副本覆盖缓存文件。副本自身先过一遍哈希校验：
    /// App 包内的资源被替换过就返回 false，不去写一份假规则。
    @discardableResult
    static func restoreBundledCache(_ item: MandatoryRuleProvider, to cache: URL) -> Bool {
        guard let bundled = item.bundledURL,
              sha256(of: bundled) == item.bundledSHA256 else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: cache)
        guard (try? fm.copyItem(at: bundled, to: cache)) != nil else { return false }
        // copyItem 会连修改时间一起复制过来（= 打包日期），mihomo 会判定缓存过期而立刻回源；
        // 拨到当前时间，让恢复出来的内容至少稳定一个 interval。
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
        return true
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func providerName(for fileName: String) -> String {
        fileName.replacingOccurrences(of: "\\.(yaml|yml)$", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// provider 中的节点不能直接作为规则目标；为每个选定节点生成一个隐藏的单节点组。
    static func ruleNodeGroupName(for ruleProviderName: String) -> String {
        "__MIDOG_RULE_NODE_\(ruleProviderName)"
    }

    struct Output {
        var yaml: String
        var providers: [String]
    }

    static func generate(data: AppData, rules: [String], configsDir: URL, ruleProvidersDir: URL) -> Result<Output, SubscriptionParser.ParseError> {
        let fm = FileManager.default
        let enabledSources = data.sources.filter {
            $0.enabled && fm.fileExists(atPath: configsDir.appendingPathComponent($0.name).path)
        }
        guard !enabledSources.isEmpty else {
            return .failure(.invalid("没有已启用且文件存在的节点来源，请在「节点来源」中至少启用一个"))
        }

        var lines: [String] = []
        lines.append("# 本文件由 midog (macOS) 自动生成，请勿手工编辑（修改会在下次生成时丢失）")
        lines.append("# 生成时间: \(isoNow())")
        lines.append("")

        // ---- 基础设置 ----
        var settings = data.settings
        settings["mode"] = .string(LOCKED_MODE) // global / direct 会绕过全部 rules，锁死
        // 只输出已知的基础设置项：任意顶层 key（listeners / sub-rules 等）都能绕过 rules
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) where ALLOWED_SETTINGS_KEYS.contains(key) {
            if key == "secret", (value.stringValue ?? "").isEmpty { continue }
            lines.append("\(JSONValue.escape(key)): \(value.jsonString)")
        }
        lines.append("geodata-mode: false")
        lines.append("geo-auto-update: false")
        lines.append("profile: {\"store-selected\": true, \"store-fake-ip\": true}")
        lines.append("")

        // ---- TUN ----
        lines.append("tun: \(JSONValue.object(data.tun).jsonString)")
        lines.append("")

        // ---- DNS / hosts ----
        var dns = data.dns
        dns["enable"] = .bool(true) // TUN 依赖内置 DNS，强制开启
        lines.append("dns: \(JSONValue.object(dns).jsonString)")
        if !data.hosts.isEmpty {
            lines.append("hosts: \(JSONValue.object(data.hosts).jsonString)")
        }
        lines.append("")

        // ---- proxy-providers：每个启用的来源一个 file provider ----
        var providerNames: [String] = []
        lines.append("proxy-providers:")
        for src in enabledSources {
            let pname = providerName(for: src.name)
            providerNames.append(pname)
            let fields: [String: JSONValue] = [
                "type": .string("file"),
                "path": .string(configsDir.appendingPathComponent(src.name).path),
                "health-check": .object([
                    "enable": .bool(true),
                    "url": .string(HEALTH_CHECK_URL),
                    "interval": .number(300),
                    "lazy": .bool(true)
                ])
            ]
            lines.append("  \(JSONValue.escape(pname)): \(JSONValue.object(fields).jsonString)")
        }
        lines.append("")

        let mandatoryNames = Set(MANDATORY_RULE_PROVIDERS.map(\.provider.name))
        // 内置强制规则集的名字被占用时以内置为准，避免用户建同名条目把它顶掉
        let ruleProviders = data.ruleProviders.filter {
            $0.enabled && !$0.name.isEmpty && !$0.url.isEmpty && !mandatoryNames.contains($0.name)
        }

        // ---- proxy-groups ----
        lines.append("proxy-groups:")
        let proxyGroup: JSONValue = .object([
            "name": .string("PROXY"),
            "type": .string("select"),
            "proxies": .array([.string("AUTO"), .string("DIRECT")]),
            "include-all-providers": .bool(true)
        ])
        let autoGroup: JSONValue = .object([
            "name": .string("AUTO"),
            "type": .string("url-test"),
            "url": .string(HEALTH_CHECK_URL),
            "interval": .number(300),
            "tolerance": .number(50),
            "include-all-providers": .bool(true)
        ])
        lines.append("  - \(proxyGroup.jsonString)")
        lines.append("  - \(autoGroup.jsonString)")
        for rp in ruleProviders where rp.targetKind == "node" {
            guard let node = normalizedRuleTarget(rp.target) else { continue }
            let exactNodePattern = "^(?:\(NSRegularExpression.escapedPattern(for: node)))$"
            let nodeGroup: JSONValue = .object([
                "name": .string(ruleNodeGroupName(for: rp.name)),
                "type": .string("select"),
                "include-all-providers": .bool(true),
                "filter": .string(exactNodePattern),
                "default-selected": .string(node),
                "empty-fallback": .string("REJECT"),
                "hidden": .bool(true)
            ])
            lines.append("  - \(nodeGroup.jsonString)")
        }
        lines.append("")

        // ---- rule-providers（远程规则集）----
        // 内置强制规则集不来自 data.json，每次生成都会重新写入
        seedMandatoryCaches(into: ruleProvidersDir)
        let emittedProviders = MANDATORY_RULE_PROVIDERS.map(\.provider) + ruleProviders
        if !emittedProviders.isEmpty {
            lines.append("rule-providers:")
            for rp in emittedProviders {
                let behavior = RULE_BEHAVIORS.contains(rp.behavior) ? rp.behavior : "classical"
                let format = RULE_FORMATS.contains(rp.format) ? rp.format : "yaml"
                let cachePath = ruleProvidersDir.appendingPathComponent(rp.name + rp.fileExtension).path
                var fields: [String: JSONValue] = [
                    "behavior": .string(behavior),
                    "format": .string(format),
                    "path": .string(cachePath)
                ]
                if rp.converted {
                    // 转换产物由 App 维护在本地缓存文件里，mihomo 直接读取
                    fields["type"] = .string("file")
                } else {
                    fields["type"] = .string("http")
                    fields["url"] = .string(rp.url)
                    fields["interval"] = .number(Double(rp.interval > 0 ? rp.interval : 86400))
                    if rp.viaProxy { fields["proxy"] = .string("PROXY") } // 通过代理下载（如 GitHub raw 被墙时）
                }
                lines.append("  \(JSONValue.escape(rp.name)): \(JSONValue.object(fields).jsonString)")
            }
            lines.append("")
        }

        // ---- rules ----
        let finalTarget = FINAL_TARGETS.contains(data.finalTarget) ? data.finalTarget : "PROXY"
        // 内置强制规则排在最前，用户规则无法在它之前插队放行
        var userRules: [String] = MANDATORY_RULE_PROVIDERS.map {
            "RULE-SET,\($0.provider.name),\(normalizedRuleTarget($0.provider.target) ?? "REJECT")"
        }
        for rule in rules {
            let trimmed = rule.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            userRules.append(trimmed)
        }
        // 未在规则里手动引用的规则集，自动追加 RULE-SET（手动写则由用户控制优先级/目标）
        for rp in ruleProviders {
            let escaped = NSRegularExpression.escapedPattern(for: rp.name)
            let pattern = "^RULE-SET\\s*,\\s*\(escaped)\\s*,"
            let referenced = userRules.contains {
                $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if !referenced {
                let target: String
                if rp.targetKind == "node", normalizedRuleTarget(rp.target) != nil {
                    target = ruleNodeGroupName(for: rp.name)
                } else {
                    target = normalizedRuleTarget(rp.target) ?? "PROXY"
                }
                userRules.append("RULE-SET,\(rp.name),\(target)")
            }
        }
        lines.append("rules:")
        for rule in userRules {
            lines.append("  - \(JSONValue.escape(rule))")
        }
        lines.append("  - \(JSONValue.escape("MATCH,\(finalTarget)"))")
        lines.append("")

        return .success(Output(yaml: lines.joined(separator: "\n"), providers: providerNames))
    }
}
