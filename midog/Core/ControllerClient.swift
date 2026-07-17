import Foundation

struct ProxyNode: Decodable {
    var name: String?
    var type: String?
    var now: String?
    var all: [String]?

    var isGroup: Bool {
        let t = (type ?? "").lowercased()
        return t == "selector" || t == "urltest" || t == "fallback" || t == "loadbalance" || t == "relay"
    }

    var isSelectable: Bool {
        (type ?? "").lowercased() == "selector"
    }
}

struct RuleProviderRuntime: Decodable {
    var ruleCount: Int?
    var updatedAt: String?
}

struct ConnectionsSnapshot {
    var count: Int
    var uploadTotal: Int
    var downloadTotal: Int
}

enum ControllerError: LocalizedError {
    case unreachable(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let m): return "内核 API 不可达: \(m)"
        case .http(let code, let m): return m.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(m)"
        }
    }
}

/// mihomo external-controller REST 客户端
struct ControllerClient {
    var controller: String   // "127.0.0.1:9090"
    var secret: String

    private var baseURL: URL? {
        URL(string: "http://\(controller)")
    }

    private func makeRequest(_ method: String, _ path: String, body: [String: Any]? = nil,
                             timeout: TimeInterval = 8) throws -> URLRequest {
        guard let base = baseURL, let url = URL(string: path, relativeTo: base) else {
            throw ControllerError.unreachable("external-controller 地址无效: \(controller)")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// 返回 (状态码, 数据)；网络层错误抛 unreachable
    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil,
                      timeout: TimeInterval = 8) async throws -> (Int, Data) {
        let req = try makeRequest(method, path, body: body, timeout: timeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (code, data)
        } catch {
            throw ControllerError.unreachable(error.localizedDescription)
        }
    }

    private func expectOK(_ result: (Int, Data)) throws {
        let (code, data) = result
        guard (200..<300).contains(code) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"] ?? ""
            throw ControllerError.http(code, message)
        }
    }

    // ---- 代理 ----

    func proxies() async throws -> [String: ProxyNode] {
        let result = try await send("GET", "/proxies")
        try expectOK(result)
        struct Wrapper: Decodable { var proxies: [String: ProxyNode] }
        return try JSONDecoder().decode(Wrapper.self, from: result.1).proxies
    }

    func selectProxy(group: String, name: String) async throws {
        let path = "/proxies/\(group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group)"
        try expectOK(await send("PUT", path, body: ["name": name]))
    }

    func delay(proxy: String, timeoutMs: Int = 5000) async throws -> Int {
        let encoded = proxy.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proxy
        let path = "/proxies/\(encoded)/delay?timeout=\(timeoutMs)&url=\(HEALTH_CHECK_URL)"
        let result = try await send("GET", path, timeout: TimeInterval(timeoutMs) / 1000 + 3)
        try expectOK(result)
        struct D: Decodable { var delay: Int }
        return try JSONDecoder().decode(D.self, from: result.1).delay
    }

    /// provider 内节点测速（这类节点不在顶层 /proxies 里，走 /proxies/{name}/delay 会 404）。
    /// url/timeout 两个参数必须携带，否则 mihomo 返回 400 Body invalid。
    func providerHealthcheck(provider: String, proxy: String, timeoutMs: Int = 5000) async throws -> Int {
        let p = provider.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? provider
        let n = proxy.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proxy
        let path = "/providers/proxies/\(p)/\(n)/healthcheck?timeout=\(timeoutMs)&url=\(HEALTH_CHECK_URL)"
        let result = try await send("GET", path, timeout: TimeInterval(timeoutMs) / 1000 + 3)
        try expectOK(result)
        struct D: Decodable { var delay: Int }
        return try JSONDecoder().decode(D.self, from: result.1).delay
    }

    /// 一次性测试整组延迟，返回 {节点名: 延迟ms}（失败的节点不在结果中）
    func groupDelay(group: String, timeoutMs: Int = 5000) async throws -> [String: Int] {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let path = "/group/\(encoded)/delay?timeout=\(timeoutMs)&url=\(HEALTH_CHECK_URL)"
        let result = try await send("GET", path, timeout: 40)
        try expectOK(result)
        return try JSONDecoder().decode([String: Int].self, from: result.1)
    }

    // ---- 配置 ----

    func reload(configPath: String) async throws {
        try expectOK(await send("PUT", "/configs?force=true", body: ["path": configPath], timeout: 30))
    }

    func patchConfigs(_ patch: [String: Any]) async throws {
        try expectOK(await send("PATCH", "/configs", body: patch))
    }

    // ---- providers ----

    func refreshProxyProvider(_ name: String) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        try expectOK(await send("PUT", "/providers/proxies/\(encoded)", timeout: 30))
    }

    /// 返回状态码（404 = 运行配置里还没有该规则集，调用方回退整体热重载）
    func refreshRuleProvider(_ name: String) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let (code, data) = try await send("PUT", "/providers/rules/\(encoded)", timeout: 30)
        if (200..<300).contains(code) || code == 404 { return code }
        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"] ?? ""
        throw ControllerError.http(code, message)
    }

    func ruleProvidersRuntime() async throws -> [String: RuleProviderRuntime] {
        let result = try await send("GET", "/providers/rules")
        try expectOK(result)
        struct Wrapper: Decodable { var providers: [String: RuleProviderRuntime] }
        return try JSONDecoder().decode(Wrapper.self, from: result.1).providers
    }

    // ---- 运行信息 ----

    func version() async throws -> String {
        let result = try await send("GET", "/version")
        try expectOK(result)
        struct V: Decodable { var version: String }
        return try JSONDecoder().decode(V.self, from: result.1).version
    }

    func connections() async throws -> ConnectionsSnapshot {
        let result = try await send("GET", "/connections")
        try expectOK(result)
        struct C: Decodable {
            struct Item: Decodable { var id: String? }
            var downloadTotal: Int?
            var uploadTotal: Int?
            var connections: [Item]?
        }
        let c = try JSONDecoder().decode(C.self, from: result.1)
        return ConnectionsSnapshot(count: c.connections?.count ?? 0,
                                   uploadTotal: c.uploadTotal ?? 0,
                                   downloadTotal: c.downloadTotal ?? 0)
    }

    /// /traffic 流式接口：每秒推送一行 {"up": n, "down": n}
    func trafficStream() async throws -> (URLSession.AsyncBytes, URLResponse) {
        let req = try makeRequest("GET", "/traffic", timeout: 3600)
        return try await URLSession.shared.bytes(for: req)
    }
}
