import Foundation
import CryptoKit

/// 订阅下载与 Clash YAML 识别/校验（移植自旧版 subscription-parser.js）
enum SubscriptionParser {

    static let userAgent = "Clash Verge Rev/2.0.0"
    static let maxBodySize = 20 * 1024 * 1024
    static let downloadTimeout: TimeInterval = 30

    static let clashTopLevelKeys: Set<String> = [
        "port", "socks-port", "mixed-port", "redir-port", "tproxy-port",
        "allow-lan", "bind-address", "mode", "log-level",
        "external-controller", "secret", "ipv6", "geodata-mode",
        "proxies", "proxy-groups", "proxy-providers", "rules",
        "rules-providers", "sub-rules", "dns", "tun", "sniffer",
        "profile", "experimental", "hosts", "routing-mark"
    ]

    static let v2rayProtocols = ["vmess", "vless", "trojan", "ss", "ssr", "hysteria", "hysteria2", "tuic", "wireguard"]

    struct Parsed {
        var content: String
        var format: String
        var warnings: [String]
    }

    enum ParseError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let m) = self { return m }
            return nil
        }
    }

    // ---- 基础工具 ----

    static func normalize(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isHtml(_ content: String) -> Bool {
        let head = String(content.prefix(500)).lowercased()
        return head.hasPrefix("<!doctype") || head.hasPrefix("<html")
            || head.range(of: "<head[\\s>]", options: .regularExpression) != nil
            || head.range(of: "<body[\\s>]", options: .regularExpression) != nil
    }

    static func isV2rayLine(_ line: String) -> Bool {
        guard let idx = line.range(of: "://") else { return false }
        let proto = String(line[line.startIndex..<idx.lowerBound]).lowercased()
        return v2rayProtocols.contains(proto)
    }

    static func isV2rayLinkList(_ content: String) -> Bool {
        let lines = content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let links = lines.filter { isV2rayLine($0) }.count
        return links > 0 && links * 2 >= lines.count
    }

    static func topLevelKeys(_ content: String) -> Set<String> {
        var keys = Set<String>()
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard !s.isEmpty, !s.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            guard let first = s.first, first != " ", first != "\t" else { continue }
            if let r = s.range(of: "^([a-zA-Z0-9_-]+):", options: .regularExpression) {
                keys.insert(String(s[r].dropLast()))
            }
        }
        return keys
    }

    static func looksLikeClashYaml(_ content: String) -> Bool {
        let normalized = normalize(content)
        guard !normalized.isEmpty, !isHtml(normalized), !isV2rayLinkList(normalized) else { return false }
        let keys = topLevelKeys(normalized)
        if keys.contains("proxies") || keys.contains("proxy-groups") || keys.contains("proxy-providers") {
            return true
        }
        let hasPort = keys.contains("mixed-port") || keys.contains("port") || keys.contains("socks-port")
        return hasPort && (keys.contains("rules") || keys.contains("proxy-groups"))
    }

    static func looksLikeBase64(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else { return false }
        if looksLikeClashYaml(trimmed) { return false }
        if trimmed.contains("proxies:") || trimmed.contains("proxy-groups:") { return false }
        let compact = trimmed.filter { !$0.isWhitespace }
        if compact.count % 4 == 1 { return false }
        return compact.range(of: "^[A-Za-z0-9+/_-]+=*$", options: .regularExpression) != nil
    }

    static func tryDecodeBase64(_ content: String) -> String? {
        let compact = content.filter { !$0.isWhitespace }
        let variants = [compact, compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")]
        for candidate in variants {
            let padded = candidate + String(repeating: "=", count: (4 - candidate.count % 4) % 4)
            guard let data = Data(base64Encoded: padded) else { continue }
            guard let decoded = String(data: data, encoding: .utf8) else { continue }
            let normalized = normalize(decoded)
            guard !normalized.isEmpty, !normalized.contains("\u{FFFD}") else { continue }
            // 拒绝明显二进制乱码：可打印字符（含中文）以外占比过高
            let junk = normalized.unicodeScalars.filter { u in
                !(u.value == 9 || u.value == 10 || u.value == 13
                  || (0x20...0x7E).contains(u.value)
                  || (0x4E00...0x9FFF).contains(u.value))
            }.count
            if Double(junk) / Double(max(normalized.unicodeScalars.count, 1)) > 0.15 { continue }
            return normalized
        }
        return nil
    }

    // ---- 校验 ----

    struct Validation {
        var valid: Bool
        var errors: [String]
        var warnings: [String]
    }

    static func validateClashYaml(_ content: String) -> Validation {
        let normalized = normalize(content)
        var errors: [String] = []
        var warnings: [String] = []

        if normalized.isEmpty {
            return Validation(valid: false, errors: ["配置内容为空"], warnings: [])
        }
        if isHtml(normalized) {
            return Validation(valid: false, errors: ["响应内容是 HTML 页面，可能是订阅失效或被拦截"], warnings: [])
        }
        if isV2rayLinkList(normalized) {
            return Validation(valid: false, errors: ["检测到 V2Ray/通用节点链接订阅，本工具需要 Clash 格式 YAML 订阅"], warnings: [])
        }

        let keys = topLevelKeys(normalized)
        if keys.isEmpty {
            return Validation(valid: false, errors: ["无法识别 YAML 结构，未找到有效的顶层配置项"], warnings: [])
        }
        if !keys.contains("proxies") && !keys.contains("proxy-providers") {
            errors.append("缺少 proxies 或 proxy-providers 段，不是有效的 Clash 配置")
        }
        if keys.contains("proxies") && !hasProxiesContent(normalized) {
            warnings.append("proxies 段为空，可能没有可用节点")
        }
        let unknown = keys.filter { !clashTopLevelKeys.contains($0) }
        if !unknown.isEmpty && unknown.count <= 5 {
            warnings.append("包含非标准顶层键: \(unknown.sorted().joined(separator: ", "))")
        }
        return Validation(valid: errors.isEmpty, errors: errors, warnings: warnings)
    }

    static func hasProxiesContent(_ content: String) -> Bool {
        var inProxies = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = s.prefix(while: { $0 == " " || $0 == "\t" }).count
            if indent == 0 && s.hasPrefix("proxies:") {
                if trimmed.range(of: "^proxies:\\s*\\[\\s*\\]", options: .regularExpression) != nil { return false }
                inProxies = true
                continue
            }
            if inProxies {
                if indent == 0 && !trimmed.hasPrefix("-") { break }
                if trimmed.hasPrefix("-") { return true }
                if trimmed.range(of: "^[a-zA-Z][\\w-]*:", options: .regularExpression) != nil { return true }
            }
        }
        return false
    }

    // ---- 解析入口 ----

    static func parse(_ raw: String) -> Result<Parsed, ParseError> {
        let content = normalize(raw)
        if content.isEmpty { return .failure(.invalid("订阅内容为空")) }

        // 1. 明文 YAML
        if looksLikeClashYaml(content) {
            let v = validateClashYaml(content)
            guard v.valid else { return .failure(.invalid(v.errors.joined(separator: "; "))) }
            return .success(Parsed(content: content.replacingOccurrences(of: "\r\n", with: "\n"),
                                   format: "clash-yaml", warnings: v.warnings))
        }
        // 2. HTML
        if isHtml(content) {
            return .failure(.invalid("订阅返回 HTML 页面，请检查 URL 是否有效或已过期"))
        }
        // 3. V2Ray 链接
        if isV2rayLinkList(content) {
            return .failure(.invalid("不支持 V2Ray 节点链接订阅，请使用 Clash 专用订阅地址"))
        }
        // 4. Base64（支持双层）
        if looksLikeBase64(content) {
            guard let decoded = tryDecodeBase64(content) else {
                return .failure(.invalid("Base64 解码失败，无法识别订阅格式"))
            }
            if isV2rayLinkList(decoded) {
                return .failure(.invalid("解码后为 V2Ray 节点链接，请换用 Clash 格式订阅"))
            }
            var candidate = decoded
            if !looksLikeClashYaml(candidate), looksLikeBase64(candidate),
               let decoded2 = tryDecodeBase64(candidate), looksLikeClashYaml(decoded2) {
                candidate = decoded2
            }
            if looksLikeClashYaml(candidate) {
                let v = validateClashYaml(candidate)
                guard v.valid else { return .failure(.invalid(v.errors.joined(separator: "; "))) }
                return .success(Parsed(content: candidate.replacingOccurrences(of: "\r\n", with: "\n"),
                                       format: "base64-clash-yaml", warnings: v.warnings))
            }
            return .failure(.invalid("Base64 解码后仍不是有效的 Clash YAML 配置"))
        }
        // 5. 兜底校验
        let v = validateClashYaml(content)
        if v.valid {
            return .success(Parsed(content: content.replacingOccurrences(of: "\r\n", with: "\n"),
                                   format: "clash-yaml", warnings: v.warnings))
        }
        return .failure(.invalid(v.errors.first ?? "无法识别的订阅格式，需要 Clash YAML 或 Base64 编码的 Clash 配置"))
    }

    // ---- 文件名 ----

    static func sha8(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }

    static func sanitizeFileName(_ name: String) -> String {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = sha8(raw.isEmpty ? "config" : raw)
        var base = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .replacingOccurrences(of: "^\\.+|\\.+$", with: "", options: .regularExpression)

        let hasNonAscii = raw.unicodeScalars.contains { $0.value > 0x7F }
        if base.isEmpty || base.range(of: "^_+$", options: .regularExpression) != nil || hasNonAscii {
            base = "sub_\(hash)"
        }
        if !base.hasSuffix(".yaml") && !base.hasSuffix(".yml") {
            base += ".yaml"
        }
        return base
    }

    static func resolveUniqueFileName(_ fileName: String, in dir: URL, sourceName: String) -> String {
        let target = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: target.path) else { return fileName }
        let hash = sha8(sourceName)
        let ext = fileName.hasSuffix(".yml") ? ".yml" : ".yaml"
        let stem = fileName.replacingOccurrences(of: "\\.(yaml|yml)$", with: "", options: .regularExpression)
        return "\(stem)_\(hash)\(ext)"
    }

    // ---- 下载 ----

    static func download(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ParseError.invalid("无效的订阅 URL（仅支持 HTTP/HTTPS）")
        }
        var request = URLRequest(url: url, timeoutInterval: downloadTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ParseError.invalid("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw ParseError.invalid("HTTP \(http.statusCode): \(preview)")
        }
        guard data.count <= maxBodySize else {
            throw ParseError.invalid("订阅内容过大（>\(maxBodySize / 1024 / 1024)MB）")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParseError.invalid("订阅内容不是有效的 UTF-8 文本")
        }
        return text
    }

    static func fetchAndParse(_ url: String) async throws -> Parsed {
        let raw = try await download(url)
        switch parse(raw) {
        case .success(let parsed): return parsed
        case .failure(let err): throw err
        }
    }
}
