import Foundation
import Combine
import NetworkExtension

@MainActor
final class FocusStore: ObservableObject {
    static let shared = FocusStore()
    @Published private(set) var state = FocusState()
    @Published private(set) var available = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var proxyStatus = ""
    @Published private(set) var now = Date()
    private var loop: Task<Void, Never>?
    private var configuredProxy: String?
    private var refreshing = false
    private var mutationEpoch = 0
    private var clock: AnyCancellable?
    @Published private(set) var needsProxyUpgrade = false
    var active: Bool { state.isActive(at: now) }
    var remaining: String { state.remaining(at: now) }

    func startPolling() {
        guard loop == nil else { return }
        clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] in self?.now = $0 }
        loop = Task {
            while !Task.isCancelled {
                now = Date()
                if !busy { await refresh() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() async {
        guard !refreshing, !busy else { return }
        let epoch = mutationEpoch
        refreshing = true
        defer { refreshing = false }
        do {
            let manager = NEFilterManager.shared()
            try await manager.loadFromPreferences()
            guard manager.isEnabled else { throw FocusFailure("请先启用 macOS 系统内容过滤") }
            let reply = try await send(FocusCommand(action: .status))
            guard epoch == mutationEpoch, !busy else { return }
            accept(reply, clearError: !available)
            available = true
            let store = Store.shared
            needsProxyUpgrade = CoreService.installed && !CoreService.supportsFocusRules
            let key = store.data.externalController + store.data.secret + String(needsProxyUpgrade)
            if configuredProxy != key {
                let result = try await send(FocusCommand(action: .configureProxy,
                                                         controller: store.data.externalController,
                                                         secret: store.data.secret))
                guard epoch == mutationEpoch, !busy else { return }
                accept(result)
                if result.error == nil {
                    configuredProxy = key
                    // Include the extension-owned provider in every future core configuration.
                    if !needsProxyUpgrade, !store.data.sources.isEmpty { _ = await store.applyChanges() }
                }
            }
        } catch {
            guard epoch == mutationEpoch, !busy else { return }
            available = false
            self.error = "系统专注服务未连接：\(error.localizedDescription)。请启用或更新系统过滤扩展。"
        }
    }

    @discardableResult
    func perform(_ command: FocusCommand) async -> Bool {
        guard !busy, available else { return false }
        busy = true
        mutationEpoch += 1
        defer { busy = false }
        error = nil
        if command.action == .start, CoreService.installed, !CoreService.supportsFocusRules {
            error = "请先点击「更新代理支持」，完成一次内核服务更新后再开始专注"
            return false
        }
        do {
            let reply = try await send(command)
            accept(reply)
            available = true
            guard reply.error == nil else { return false }
            if command.action == .start || command.action == .add {
                let store = Store.shared
                if !store.data.sources.isEmpty {
                    let result = await store.applyChanges()
                    if let error = result.error { proxyStatus = "代理配置未更新：" + error }
                }
            }
            return true
        } catch {
            // A timeout may occur after persistence: refresh before allowing another mutation.
            available = false
            self.error = "操作结果尚未确认，正在重新连接系统专注服务：\(error.localizedDescription)"
            return false
        }
    }

    private func accept(_ reply: FocusReply, clearError: Bool = false) {
        state = reply.state
        if reply.error != nil || clearError { error = reply.error }
        proxyStatus = reply.proxyStatus ?? ""
        now = Date()
    }

    private func send(_ command: FocusCommand) async throws -> FocusReply {
        let bytes = try JSONEncoder().encode(command)
        let requirement = try FocusIPC.requirement(identifier: "com.xx.midog.filter")
        return try await withCheckedThrowingContinuation { continuation in
            let call = FocusCall(continuation)
            let connection = NSXPCConnection(machServiceName: FocusIPC.service, options: .privileged)
            call.connection = connection
            connection.remoteObjectInterface = NSXPCInterface(with: FocusRemote.self)
            connection.setCodeSigningRequirement(requirement)
            connection.interruptionHandler = { call.finish(.failure(FocusFailure("系统扩展连接中断"))) }
            connection.invalidationHandler = { call.finish(.failure(FocusFailure("系统扩展不可用"))) }
            connection.resume()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ call.finish(.failure($0)) }) as? FocusRemote else {
                call.finish(.failure(FocusFailure("系统扩展接口不可用"))); return
            }
            remote.perform(bytes) { response in
                do { call.finish(.success(try JSONDecoder().decode(FocusReply.self, from: response))) }
                catch { call.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                call.finish(.failure(FocusFailure("系统扩展响应超时")))
            }
        }
    }
}

nonisolated private final class FocusCall: @unchecked Sendable {
    let lock = NSLock()
    var connection: NSXPCConnection?
    var continuation: CheckedContinuation<FocusReply, Error>?
    init(_ continuation: CheckedContinuation<FocusReply, Error>) { self.continuation = continuation }
    func finish(_ result: Result<FocusReply, Error>) {
        lock.lock()
        let completion = continuation
        continuation = nil
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        guard let completion else { return }
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        completion.resume(with: result)
    }
}
