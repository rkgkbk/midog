import Foundation

/// 远程规则集内容识别与转换（移植自旧版 ruleset-parser.js）：
/// - 自动识别 base64 编码（如 gfwlist）并解码
/// - 自动识别格式（yaml payload / 纯文本）与行为（classical / domain / ipcidr）
/// - AutoProxy(gfwlist) 格式转换为 mihomo domain 规则列表
enum RulesetParser {

    static let classicalRuleTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD",
        "GEOSITE", "GEOIP", "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "IP-ASN",
        "SRC-GEOIP", "SRC-IP-ASN", "SRC-IP-CIDR", "SRC-IP-SUFFIX",
        "SRC-PORT", "DST-PORT", "IN-PORT", "IN-TYPE", "IN-USER", "IN-NAME",
        "PROCESS-PATH", "PROCESS-PATH-REGEX", "PROCESS-NAME", "PROCESS-NAME-REGEX",
        "UID", "NETWORK", "DSCP", "RULE-SET", "SUB-RULE", "AND", "OR", "NOT", "MATCH"
    ]

    static let ipv4Pattern = "^\\d{1,3}(\\.\\d{1,3}){3}(/\\d{1,2})?$"
    static let ipv6Pattern = "^[0-9a-fA-F:]*:[0-9a-fA-F:.]+(/\\d{1,3})?$"
    static let domainLinePattern = "^(\\+\\.|\\*\\.|\\.)?[a-zA-Z0-9_-]+([.*][a-zA-Z0-9_-]+)+$"
    static let hostPattern = "^[a-z0-9_-]+(\\.[a-z0-9_-]+)+$"

    struct Analysis {
        var sourceFormat: String
        var behavior: String
        var format: String
        var converted: Bool
        var text: String
        var ruleCount: Int
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func significantLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // ---- AutoProxy / gfwlist ----

    static func isAutoProxy(_ content: String) -> Bool {
        let lines = significantLines(content)
        guard !lines.isEmpty else { return false }
        if lines[0].lowercased().hasPrefix("[autoproxy") { return true }
        let marked = lines.filter {
            $0.hasPrefix("||") || $0.hasPrefix("@@")
                || matches($0, "^\\|https?:")
        }.count
        return marked >= 5 && Double(marked) / Double(lines.count) > 0.1
    }

    /// AutoProxy 规则行提取域名：
    /// ||host → 后缀匹配 +.host；|http://host → 精确 host；.host / 裸域名 → +.host
    /// 忽略注释(!)、白名单(@@)、正则(/../)、IP、含通配符宿主等无法映射的行
    static func convertAutoProxyToDomains(_ content: String) -> [String] {
        var out = Set<String>()
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("@@") { continue }
            if matches(line, "^/.*/$") { continue } // 正则规则

            var rest = line
            var suffix = true
            if line.hasPrefix("||") {
                rest = String(line.dropFirst(2))
            } else if line.hasPrefix("|") {
                rest = String(line.dropFirst(1))
                    .replacingOccurrences(of: "^https?://", with: "", options: [.regularExpression, .caseInsensitive])
                suffix = false // URL 前缀匹配 → 精确域名
            } else if line.hasPrefix(".") {
                rest = String(line.dropFirst(1))
            } else if !matches(line, domainLinePattern) {
                continue // 关键字/路径片段无法映射为域名规则
            }

            var host = rest.split(whereSeparator: { "/^?#:".contains($0) })
                .first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            host = host.replacingOccurrences(of: "^\\.+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\.+$", with: "", options: .regularExpression)
            if host.hasPrefix("*.") { host = String(host.dropFirst(2)); suffix = true }
            if host.isEmpty || host.contains("*") { continue }
            if matches(host, ipv4Pattern) { continue } // domain 行为无法承载 IP 规则
            if !matches(host, hostPattern) { continue }

            out.insert(suffix ? "+." + host : host)
        }
        // 精确域名若已被同名后缀规则覆盖则去重
        for d in out where !d.hasPrefix("+.") && out.contains("+." + d) {
            out.remove(d)
        }
        return out.sorted()
    }

    // ---- 分类 ----

    static func classifyEntries(_ entries: [String]) -> String? {
        var classical = 0, ipcidr = 0, domain = 0
        for entry in entries.prefix(500) {
            let line = entry.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains(","),
               let head = line.split(separator: ",").first,
               classicalRuleTypes.contains(head.trimmingCharacters(in: .whitespaces).uppercased()) {
                classical += 1
            } else if matches(line, ipv4Pattern) || matches(line, ipv6Pattern) {
                ipcidr += 1
            } else if matches(line, domainLinePattern) {
                domain += 1
            }
        }
        if classical == 0 && ipcidr == 0 && domain == 0 { return nil }
        if classical >= ipcidr && classical >= domain { return "classical" }
        return ipcidr >= domain ? "ipcidr" : "domain"
    }

    static func extractYamlPayload(_ content: String) -> [String] {
        var items: [String] = []
        var inPayload = false
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.range(of: "^payload\\s*:", options: .regularExpression) != nil {
                inPayload = true
                continue
            }
            if !inPayload { continue }
            if let m = line.range(of: "^\\s+-\\s*(.+?)\\s*$", options: .regularExpression) {
                var item = String(line[m]).trimmingCharacters(in: .whitespaces)
                item = String(item.dropFirst()) // 去掉 "-"
                    .trimmingCharacters(in: .whitespaces)
                item = item.replacingOccurrences(of: "\\s+#.*$", with: "", options: .regularExpression)
                if item.count >= 2, let q = item.first, (q == "\"" || q == "'"), item.hasSuffix(String(q)) {
                    item = String(item.dropFirst().dropLast())
                }
                if !item.isEmpty { items.append(item) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty,
                      line.range(of: "^\\S", options: .regularExpression) != nil {
                break // 进入下一个顶层键
            }
        }
        return items
    }

    // ---- 入口 ----

    static func analyze(_ raw: String) -> Result<Analysis, SubscriptionParser.ParseError> {
        var content = SubscriptionParser.normalize(raw).replacingOccurrences(of: "\r\n", with: "\n")
        if content.isEmpty { return .failure(.invalid("内容为空")) }

        let head = String(content.prefix(500)).lowercased()
        if head.hasPrefix("<!doctype") || head.hasPrefix("<html") || SubscriptionParser.isHtml(content) {
            return .failure(.invalid("返回的是 HTML 页面，URL 可能失效或被拦截"))
        }

        var wasBase64 = false
        if SubscriptionParser.looksLikeBase64(content), let decoded = SubscriptionParser.tryDecodeBase64(content) {
            content = decoded.replacingOccurrences(of: "\r\n", with: "\n")
            wasBase64 = true
        }
        func tag(_ fmt: String) -> String { wasBase64 ? "\(fmt)+base64" : fmt }

        if isAutoProxy(content) {
            let domains = convertAutoProxyToDomains(content)
            guard !domains.isEmpty else { return .failure(.invalid("gfwlist/AutoProxy 内容中未提取到有效域名")) }
            return .success(Analysis(sourceFormat: tag("gfwlist"), behavior: "domain", format: "text",
                                     converted: true, text: domains.joined(separator: "\n") + "\n",
                                     ruleCount: domains.count))
        }

        if content.range(of: "^payload\\s*:", options: [.regularExpression]) != nil
            || content.range(of: "\npayload\\s*:", options: [.regularExpression]) != nil {
            let items = extractYamlPayload(content)
            guard !items.isEmpty else { return .failure(.invalid("yaml payload 为空")) }
            guard let behavior = classifyEntries(items) else { return .failure(.invalid("无法识别 payload 条目类型")) }
            return .success(Analysis(sourceFormat: tag("yaml"), behavior: behavior, format: "yaml",
                                     converted: wasBase64, text: content + "\n", ruleCount: items.count))
        }

        let lines = significantLines(content)
        guard !lines.isEmpty else { return .failure(.invalid("内容中没有有效规则行")) }
        guard let behavior = classifyEntries(lines) else {
            return .failure(.invalid("无法识别规则行类型（非域名/IP/classical 规则）"))
        }
        return .success(Analysis(sourceFormat: tag("text"), behavior: behavior, format: "text",
                                 converted: wasBase64, text: content + "\n", ruleCount: lines.count))
    }
}
