import Foundation

/// The extension refreshes the file provider even while the app is closed, including at expiry.
final class FocusProxySync {
    private struct Settings: Codable, Equatable { var controller: String; var secret: String }
    private let file = FocusIPC.directory.appendingPathComponent("proxy.json")
    private var settings: Settings?
    private let lock = NSLock()
    private var inFlight = false
    private var message = "代理内核未配置；系统过滤独立生效"
    private var lastSuccess: String?
    private var lastAttempt = Date.distantPast
    var status: String { lock.lock(); defer { lock.unlock() }; return message }

    func load() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        }
    }

    func configure(controller: String, secret: String) throws {
        guard let parts = URLComponents(string: "http://" + controller),
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(parts.host ?? ""),
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil, !secret.isEmpty else {
            throw FocusFailure("专注代理规则只支持带密钥的本机 controller")
        }
        let next = Settings(controller: controller, secret: secret)
        guard next != settings else { return }
        // The parent is root-owned; create the credentials file privately before writing secrets.
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw FocusFailure("无法保存代理连接配置")
            }
        }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        settings = next
        lock.lock(); lastSuccess = nil; lock.unlock()
    }

    func refresh(state: FocusState) {
        guard let settings else { return }
        let signature = state.proxyRules + settings.controller + settings.secret
        lock.lock()
        guard !inFlight, signature != lastSuccess || Date().timeIntervalSince(lastAttempt) > 30 else {
            lock.unlock(); return
        }
        inFlight = true
        lastAttempt = Date()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            var error: String?
            do {
                _ = try Self.request(settings, "PUT", "/providers/rules/" + FocusIPC.providerName)
                if state.isActive() {
                    let data = try Self.request(settings, "GET", "/connections")
                    struct Snapshot: Decodable {
                        struct Item: Decodable {
                            struct Metadata: Decodable { var host: String? }
                            var id: String; var metadata: Metadata
                        }
                        var connections: [Item]?
                    }
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                    for connection in snapshot.connections ?? [] where state.blocks(connection.metadata.host ?? "") {
                        // mihomo looks up the literal route parameter. Escaping UUID hyphens
                        // as %2D returns success without finding or closing the connection.
                        guard let uuid = UUID(uuidString: connection.id) else { continue }
                        let id = uuid.uuidString.lowercased()
                        _ = try Self.request(settings, "DELETE", "/connections/" + id)
                    }
                }
            } catch let caught { error = caught.localizedDescription }
            self.lock.lock()
            self.inFlight = false
            if error == nil { self.lastSuccess = signature }
            self.message = error == nil ? "代理专注规则已同步" : "代理规则等待同步（内核未运行或规则尚未加载）"
            self.lock.unlock()
        }
    }

    private static func request(_ settings: Settings, _ method: String, _ path: String) throws -> Data {
        guard let url = URL(string: "http://" + settings.controller + path) else { throw FocusFailure("代理地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = method
        request.setValue("Bearer " + settings.secret, forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResponseBox()
        // Never use a system proxy for the local controller, or follow a redirect with credentials.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        let task = session.dataTask(with: request) { data, response, error in
            result.data = data
            result.ok = error == nil && (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            semaphore.signal()
        }
        task.resume()
        let completed = semaphore.wait(timeout: .now() + 3) == .success
        session.invalidateAndCancel()
        guard completed, result.ok else { throw FocusFailure("代理 API 暂不可用") }
        return result.data ?? Data()
    }
}

private final class ResponseBox: @unchecked Sendable { var data: Data?; var ok = false }
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
