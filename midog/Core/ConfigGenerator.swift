import Foundation

/// 主配置生成器（移植自旧版 config-generator.js）：
/// - 订阅/本地配置作为 proxy-providers (type: file) 引用，节点与主配置解耦
/// - YAML 采用 "key: <JSON>" 形式输出（YAML 1.2 是 JSON 的超集），避免手写 YAML 序列化
/// - 转换型规则集（base64/gfwlist）由 App 下载转换后写入本地文件，以 type: file 引用
///   —— 旧版需要 Node 服务常驻提供 HTTP 回源，这里去掉了这层依赖
enum ConfigGenerator {

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
        for (key, value) in data.settings.sorted(by: { $0.key < $1.key }) {
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
            let provider: JSONValue = .object([
                "type": .string("file"),
                "path": .string(configsDir.appendingPathComponent(src.name).path),
                "health-check": .object([
                    "enable": .bool(true),
                    "url": .string(HEALTH_CHECK_URL),
                    "interval": .number(300),
                    "lazy": .bool(true)
                ])
            ])
            lines.append("  \(JSONValue.escape(pname)): \(provider.jsonString)")
        }
        lines.append("")

        let ruleProviders = data.ruleProviders.filter { $0.enabled && !$0.name.isEmpty && !$0.url.isEmpty }

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
        if !ruleProviders.isEmpty {
            lines.append("rule-providers:")
            for rp in ruleProviders {
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
        var userRules: [String] = []
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
