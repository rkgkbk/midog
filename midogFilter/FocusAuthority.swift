import Foundation

/// All mutations and disk writes are serialized here, outside the UI process.
final class FocusAuthority: NSObject, FocusRemote, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "com.xx.midog.focus")
    private let listener = NSXPCListener(machServiceName: FocusIPC.service)
    private var timer: DispatchSourceTimer?
    private var state = FocusState()
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
        state = try persistence.load()
        try persistence.publish(state)
        try proxy.load()
        rulesChanged?(state)
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(try FocusIPC.requirement(identifier: "com.xx.midog"))
        listener.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.persistence.publish(self.state); self.storageError = nil }
            catch { self.storageError = error.localizedDescription }
            self.proxy.refresh(state: self.state)
        }
        self.timer = timer
        timer.resume()
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
                let command = try JSONDecoder().decode(FocusCommand.self, from: request)
                if command.action == .configureProxy {
                    try self.proxy.configure(controller: command.controller ?? "", secret: command.secret ?? "")
                } else if command.action != .status {
                    var next = self.state
                    try next.apply(command)
                    try self.persistence.save(next)
                    self.state = next
                    self.rulesChanged?(next)
                    try self.persistence.publish(self.state)
                }
                self.proxy.refresh(state: self.state)
            } catch { failure = error.localizedDescription }
            let response = FocusReply(state: self.state, error: failure ?? self.storageError,
                                      proxyStatus: self.proxy.status)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

}
