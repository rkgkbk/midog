import Foundation

/// All mutations and disk writes are serialized here, outside the UI process.
final class FocusAuthority: NSObject, FocusRemote, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "com.xx.midog.focus")
    private let listener = NSXPCListener(machServiceName: FocusIPC.service)
    private var timer: DispatchSourceTimer?
    private var state = FocusState()
    private var wasActive = false
    private var adultRules = ""
    private var storageError: String?
    private let persistence = FocusPersistence(directory: FocusIPC.directory)
    private let proxy = FocusProxySync()
    var rulesChanged: ((FocusState) -> Void)?

    func start() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: FocusIPC.directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let attributes = try fm.attributesOfItem(atPath: FocusIPC.directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else {
            throw FocusFailure("专注数据目录必须由系统拥有且不可被其他用户写入")
        }
        // Do not silently replace a damaged active session with an empty one.
        guard let url = Bundle.main.url(forResource: "category-porn", withExtension: "list") else {
            throw FocusFailure("缺少内置过滤规则")
        }
        adultRules = try String(contentsOf: url, encoding: .utf8)
        state = try persistence.load()
        if state.restoreFilteringIfNeeded() { try persistence.save(state) }
        try persistence.publish(state, adultRules: adultRules)
        try proxy.load()
        wasActive = state.isActive()
        rulesChanged?(state)
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(try FocusIPC.requirement(identifier: "com.xx.midog"))
        listener.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let active = self.state.isActive()
            if active != self.wasActive {
                self.wasActive = active
                self.rulesChanged?(self.state)
            }
            do {
                try self.restoreFiltering()
                try self.persistence.publish(self.state, adultRules: self.adultRules)
                self.storageError = nil
            }
            catch { self.storageError = error.localizedDescription }
            self.proxy.refresh(state: self.state)
        }
        self.timer = timer
        timer.resume()
    }

    private func restoreFiltering() throws {
        var next = state
        guard next.restoreFilteringIfNeeded() else { return }
        // Restore in memory even if persistence fails; retry saving on the next tick.
        rulesChanged?(next)
        try persistence.save(next)
        state = next
    }

    func stop() { timer?.cancel(); listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FocusRemote.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func perform(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            var failure: String?
            do {
                try self.restoreFiltering()
                let command = try JSONDecoder().decode(FocusCommand.self, from: request)
                if command.action == .configureProxy {
                    try self.proxy.configure(controller: command.controller ?? "", secret: command.secret ?? "")
                } else if command.action != .status {
                    var next = self.state
                    try next.apply(command)
                    try self.persistence.save(next)
                    self.state = next
                    self.wasActive = next.isActive()
                    self.rulesChanged?(next)
                    try self.persistence.publish(self.state, adultRules: self.adultRules)
                }
                self.proxy.refresh(state: self.state)
            } catch { failure = error.localizedDescription }
            let response = FocusReply(state: self.state, error: failure ?? self.storageError,
                                      proxyStatus: self.proxy.status)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

}
