import Foundation
import AppKit
import Combine

struct LogEntry: Identifiable, Equatable {
    enum Level: String { case info, error, system }
    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}

enum DelayState: Equatable {
    case testing
    case ms(Int)
    case timeout          // 节点测速超时
    case failed(String)   // 其它失败（HTTP 错误、API 不可达等），关联原因

    var text: String {
        switch self {
        case .testing: return "…"
        case .ms(let v): return "\(v) ms"
        case .timeout: return "超时"
        case .failed: return "失败"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct ApplyResult {
    var regenerated = false
    var reloaded = false
    var error: String?

    /// 用户可读的后缀说明
    var note: String {
        if reloaded { return "，配置已热重载" }
        if regenerated { return "，配置已更新" }
        return ""
    }
}

/// 占用端口的进程
struct PortHolder: Identifiable, Equatable, Sendable {
    let pid: Int32
    let name: String
    var id: Int32 { pid }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // ---- 持久数据 ----
    @Published var data: AppData
    @Published var rulesText: String

    // ---- 运行状态 ----
    @Published var running = false
    @Published var pid: Int32?
    @Published var connected = false            // external-controller 可达
    @Published var contentFilterStatus = "正在启用系统内容过滤"
    @Published var contentFilterBusy = false
    @Published var coreVersion = ""
    @Published var startedAt: Date?
    @Published var proxies: [String: ProxyNode] = [:]
    @Published var delays: [String: DelayState] = [:]
    @Published var testingAll = false
    @Published var tunActive = false
    @Published var privileged = false
    @Published var logs: [LogEntry] = []
    @Published var upRate = 0
    @Published var downRate = 0
    @Published var upHistory: [Double] = []
    @Published var downHistory: [Double] = []
    @Published var connCount = 0
    @Published var totalUp = 0
    @Published var totalDown = 0
    @Published var ruleRuntime: [String: RuleProviderRuntime] = [:]
    /// 本次启动已自动恢复过的内置规则集，避免重载失败时死循环
    private var lastIntegrityRepair: Date?
    private var lastLegacyRoutingRepair: Date?
    @Published var busy = false                 // 进程启停中
    @Published var startupError: String?        // 启动失败/异常退出的常驻错误横幅
    @Published var conflictPorts: [Int] = []    // 上次启动失败时被占用的端口
    @Published var portHolders: [PortHolder] = []

    // ---- UI ----
    @Published var toasts: [Toast] = []

    private var trafficTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private let maxLogs = 500
    private let currentRouteDelayRefreshInterval: TimeInterval = 300
    private var lastAutoDelayTestAt: [String: Date] = [:]

    var client: ControllerClient {
        ControllerClient(controller: data.externalController, secret: data.secret)
    }

    /// 内核固定为 app 内置、由 KernelInstaller 释放出来的那一份
    var kernelPath: String { KernelInstaller.installed.path }

    /// TUN 显示状态：运行中看实际网卡，未运行看持久化设置（与旧版 web 端一致）
    var tunDisplayOn: Bool {
        running ? tunActive : data.tunEnabled
    }

    var activeGroupName: String {
        data.mode == "global" ? "GLOBAL" : "PROXY"
    }

    // ============ 初始化 ============

    private init() {
        AppPaths.ensure()
        data = Self.loadData()
        rulesText = Self.loadRulesText()
        data.syncLocalFiles(configsDir: AppPaths.configsDir)
        privileged = CoreService.installed
        // launchd 重启会重新读取磁盘配置；UI 重开时必须继续使用其中的同一把密钥。
        saveData()
    }

    private static func loadData() -> AppData {
        guard let raw = try? Data(contentsOf: AppPaths.dataFile) else { return AppData() }
        do {
            return try JSONDecoder().decode(AppData.self, from: raw)
        } catch {
            // 数据损坏时保留原文件备份，绝不静默覆盖
            try? FileManager.default.copyItem(at: AppPaths.dataFile,
                                              to: AppPaths.dataDir.appendingPathComponent("data.json.corrupt.bak"))
            return AppData()
        }
    }

    private static func loadRulesText() -> String {
        if let text = try? String(contentsOf: AppPaths.rulesFile, encoding: .utf8) {
            return text.replacingOccurrences(of: "\r\n", with: "\n")
        }
        let initial = (Defaults.rulesFileHeader + Defaults.rules).joined(separator: "\n") + "\n"
        try? initial.write(to: AppPaths.rulesFile, atomically: true, encoding: .utf8)
        return initial
    }

    func saveData() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(data) {
            try? encoded.write(to: AppPaths.dataFile)
        }
    }

    func saveRulesText(_ text: String) {
        rulesText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let out = rulesText.hasSuffix("\n") ? rulesText : rulesText + "\n"
        try? out.write(to: AppPaths.rulesFile, atomically: true, encoding: .utf8)
    }

    // ============ 配置生成与应用 ============

    /// 生成主配置（每次重读 rules.txt，支持外部编辑器直接改文件）
    func generateConfig() -> String? {
        if let text = try? String(contentsOf: AppPaths.rulesFile, encoding: .utf8) {
            rulesText = text.replacingOccurrences(of: "\r\n", with: "\n")
        }
        let rules = rulesText.components(separatedBy: "\n")
        switch ConfigGenerator.generate(data: data, rules: rules,
                                        configsDir: AppPaths.configsDir,
                                        ruleProvidersDir: AppPaths.ruleProvidersDir) {
        case .success(let output):
            do {
                try output.yaml.write(to: AppPaths.outputConfig, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return "写入配置文件失败: \(error.localizedDescription)"
            }
        case .failure(let err):
            return err.localizedDescription
        }
    }

    /// 数据变更后统一入口：重新生成主配置；若内核在运行则热重载（绝不重启进程）
    func applyChanges() async -> ApplyResult {
        if let error = generateConfig() {
            return ApplyResult(regenerated: false, reloaded: false, error: error)
        }
        guard running else {
            return ApplyResult(regenerated: true, reloaded: false)
        }
        do {
            try await client.reload(configPath: AppPaths.outputConfig.path)
            return ApplyResult(regenerated: true, reloaded: true)
        } catch {
            return ApplyResult(regenerated: true, reloaded: false, error: "热重载失败: \(error.localizedDescription)")
        }
    }

    // ============ 内核安装 ============

    /// 启动时把内置内核释放出来
    func bootstrapKernel() async {
        do {
            _ = try await Task.detached { try KernelInstaller.installIfNeeded() }.value
            privileged = CoreService.installed
        } catch {
            appendLog(.system, "内置内核释放失败：\(error.localizedDescription)")
            toast(error.localizedDescription, error: true)
        }
    }

    /// 占用者若不属于当前用户，普通 lsof 查不到，提权后重查一次
    func revealPortHolders() async {
        guard !conflictPorts.isEmpty else { return }
        busy = true
        defer { busy = false }
        let ports = conflictPorts
        do {
            let found = try await Task.detached { try Store.listeningProcesses(ports: ports, elevated: true) }.value
            portHolders = found
            if found.isEmpty {
                toast("未查到占用进程，端口可能已释放", error: true)
            }
        } catch {
            toast(error.localizedDescription, error: true)
        }
    }

    /// 结束占用端口的进程。与 lsof 同理：setuid 跑成 root 的进程普通权限杀不掉，回退到系统授权框。
    func terminateHolder(_ holder: PortHolder) async {
        busy = true
        defer { busy = false }
        let pid = holder.pid

        let result = kill(pid, SIGTERM)
        let failure = errno
        if result != 0 {
            switch failure {
            case ESRCH:
                break   // 已经退出了，当作成功
            case EPERM:
                do {
                    _ = try await Task.detached { try Privileged.run("/bin/kill -TERM \(pid)") }.value
                } catch {
                    toast(error.localizedDescription, error: true)
                    return
                }
            default:
                toast("结束 \(holder.name) 失败：\(String(cString: strerror(failure)))", error: true)
                return
            }
        }

        guard await Self.waitForExit(pid: pid) else {
            toast("\(holder.name) (PID \(pid)) 未在预期时间内退出", error: true)
            return
        }
        appendLog(.system, "已结束占用端口的进程 \(holder.name) (PID \(pid))")
        toast("已结束 \(holder.name)")

        portHolders.removeAll { $0.pid == pid }
        // 端口全腾出来了才收起横幅
        if portConflicts().isEmpty {
            startupError = nil
            conflictPorts = []
            portHolders = []
        }
    }

    /// 轮询到进程消失为止。kill(pid, 0) 对存活的 root 进程返回 EPERM，只有 ESRCH 才代表真的没了。
    nonisolated static func waitForExit(pid: Int32, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // ============ 进程控制 ============

    func startCore() async {
        if let servicePID = CoreService.pid() {
            pid = servicePID
            running = true
            privileged = true
            toast("内核已在运行中")
            return
        }
        guard !running else {
            toast("内核已在运行中", error: true)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: kernelPath) else {
            toast("内置内核尚未释放成功，请重启应用", error: true)
            return
        }
        busy = true
        defer { busy = false }

        if let error = generateConfig() {
            toast(error, error: true)
            return
        }

        // 端口预检：mihomo 端口被占用时不会退出，而是变成不监听任何端口的僵尸进程，
        // 且本应用会误连到占用者的 API —— 必须在启动前拦截
        let conflicts = portConflicts()
        if !conflicts.isEmpty {
            conflictPorts = conflicts
            portHolders = (try? Self.listeningProcesses(ports: conflicts)) ?? []
            let ports = conflicts.map(String.init).joined(separator: ", ")
            startupError = "无法启动内核：端口 \(ports) 已被占用。请结束占用进程，或在「设置」中修改本应用的端口。"
            toast("端口被占用，内核未启动", error: true)
            return
        }

        do {
            let source = kernelPath
            try await Task.detached {
                try CoreService.installAndStart(source: source, dataDir: AppPaths.dataDir)
            }.value
            pid = await CoreService.waitForPID()
            running = pid != nil
            startedAt = running ? Date() : nil
            privileged = true
            startupError = nil
            conflictPorts = []
            portHolders = []
            appendLog(.system, "已注册 launchd 内核服务" + (pid.map { ", PID: \($0)" } ?? ""))
            if running {
                toast("内核服务已启动")
            } else {
                startupError = "launchd 已注册服务，但 mihomo 未启动。请检查 config.yaml 和 launchctl 服务状态。"
                toast(startupError ?? "内核启动失败", error: true)
            }
            // 转换型规则集若超期，启动后顺手刷新
            Task { await refreshStaleConvertedProviders() }
            // 内置强制规则集的条数校验不能只等用户翻到规则页，启动后主动跑一次
            Task { await verifyMandatoryAfterStart() }
        } catch {
            toast(error.localizedDescription, error: true)
        }
    }

    // ============ 冷静期 ============

    /// 停止内核 / 关 TUN 会让拦截失效，不允许一键完成：
    /// 第一次点击开始 15 分钟冷静期，期满后 5 分钟内再点一次才真正执行。
    /// ponytail: 只存在内存里、只拦 App 内操作；管理员仍可直接停用 launchd 服务。
    static let cooldown: TimeInterval = 15 * 60
    static let unlockWindow: TimeInterval = 5 * 60
    private var unlockAt: Date?

    func passCooldown(_ action: String) -> Bool {
        let now = Date()
        if let at = unlockAt, now >= at, now < at + Self.unlockWindow {
            unlockAt = nil
            return true
        }
        if let at = unlockAt, now < at {
            let minutes = Int((at.timeIntervalSince(now) / 60).rounded(.up))
            toast("冷静期中，\(minutes) 分钟后可再次\(action)", error: true)
            return false
        }
        unlockAt = now + Self.cooldown
        appendLog(.system, "请求\(action)，冷静期 15 分钟")
        toast("已开始 15 分钟冷静期，期满后 5 分钟内再点一次即可\(action)", error: true)
        return false
    }

    func stopCore() async {
        guard running else {
            toast("内核未运行", error: true)
            return
        }
        guard passCooldown("停止内核") else { return }
        busy = true
        defer { busy = false }
        do {
            try await Task.detached { try CoreService.stop() }.value
        } catch {
            toast(error.localizedDescription, error: true)
            return
        }
        running = false
        pid = nil
        startedAt = nil
        privileged = false
        connected = false
        stopTrafficStream()
        stopLogStream()
        proxies = [:]
        connCount = 0
        upRate = 0
        downRate = 0
        toast("内核已停止")
    }

    /// 重新安装内置版本和相同参数，然后由 launchd 启动。
    func restartCore() async {
        busy = true
        defer { busy = false }
        if let error = generateConfig() {
            toast(error, error: true)
            return
        }
        do {
            let source = kernelPath
            try await Task.detached {
                try CoreService.installAndStart(source: source, dataDir: AppPaths.dataDir)
            }.value
            pid = await CoreService.waitForPID()
            running = pid != nil
            startedAt = running ? Date() : nil
            connected = false
            stopTrafficStream()
            stopLogStream()
            toast(running ? "内核已重启" : "launchd 重启后未发现 mihomo 进程", error: !running)
        } catch {
            toast(error.localizedDescription, error: true)
        }
    }

    // ============ 端口预检 ============

    /// 返回被占用的端口列表（检查 mixed-port / external-controller / DNS listen）
    private func portConflicts() -> [Int] {
        var conflicts: [Int] = []

        if let mixed = data.settings["mixed-port"]?.intValue, mixed > 0,
           Self.portInUse(host: "127.0.0.1", port: mixed) {
            conflicts.append(mixed)
        }
        if let (host, port) = Self.splitHostPort(data.externalController),
           Self.portInUse(host: host, port: port) {
            conflicts.append(port)
        }
        if let listen = data.dns["listen"]?.stringValue,
           let (host, port) = Self.splitHostPort(listen),
           Self.portInUse(host: host, port: port) || Self.portInUse(host: host, port: port, udp: true) {
            conflicts.append(port)
        }
        return Array(Set(conflicts)).sorted()
    }

    nonisolated static func splitHostPort(_ s: String) -> (String, Int)? {
        guard let idx = s.lastIndex(of: ":"), let port = Int(s[s.index(after: idx)...]), port > 0 else { return nil }
        let host = String(s[..<idx])
        return (host.isEmpty ? "127.0.0.1" : host, port)
    }

    /// 尝试 bind 判断端口是否被占用
    nonisolated static func portInUse(host: String, port: Int, udp: Bool = false) -> Bool {
        let fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        let ip = inet_addr(host)
        addr.sin_addr.s_addr = (ip == INADDR_NONE) ? INADDR_ANY : ip

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0
    }

    /// 查出占用这些端口的进程。
    ///
    /// lsof 没有 setuid 位，跑起来只有本应用的权限，因而**看不到其他用户的进程**——
    /// 而 mihomo 靠 setuid 跑成 root，上一次没退干净的内核恰恰是最常见的冲突源。
    /// 这类占用者只有 elevated 时才查得到，代价是弹一次授权框。
    nonisolated static func listeningProcesses(ports: [Int], elevated: Bool = false) throws -> [PortHolder] {
        guard !ports.isEmpty else { return [] }
        // -sTCP:LISTEN 只约束 TCP，不会滤掉 UDP 结果；没有它则连到该端口的客户端也会被算作占用者
        let args = ["-nP"] + ports.flatMap { ["-iTCP:\($0)", "-iUDP:\($0)"] } + ["-sTCP:LISTEN", "-Fpc"]
        let output: String
        if elevated {
            // lsof 查无结果时退出码为 1，do shell script 会据此报错，故补 || true
            let command = (["/usr/sbin/lsof"] + args).map(Privileged.quoted).joined(separator: " ")
            output = try Privileged.run(command + " || true")
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
        }

        // -F 输出按进程分块：p<pid> 起一块，c<命令名> 紧随其后（名字可含空格）
        var holders: [PortHolder] = []
        var pid: Int32?
        for line in output.split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p":
                pid = Int32(line.dropFirst())
            case "c":
                if let pid, !holders.contains(where: { $0.pid == pid }) {
                    holders.append(PortHolder(pid: pid, name: String(line.dropFirst())))
                }
            default:
                break
            }
        }
        return holders
    }

    private func appendLog(_ level: LogEntry.Level, _ message: String) {
        logs.append(LogEntry(date: Date(), level: level, message: message))
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }

    func clearLogs() {
        logs = []
    }

    // ============ 模式 / TUN ============

    func setMode(_ mode: String) async {
        let m = mode.lowercased()
        // 出站模式锁定：global / direct 会让 rules（含内置强制规则集）整段失效
        guard m == LOCKED_MODE else {
            toast("出站模式已锁定为 \(LOCKED_MODE.uppercased())，不可切换", error: true)
            return
        }
        guard ["rule", "global", "direct"].contains(m), m != data.mode else { return }
        data.mode = m
        saveData()
        _ = generateConfig()
        if running {
            do {
                try await client.patchConfigs(["mode": m])
            } catch {
                toast("模式切换未同步到运行内核: \(error.localizedDescription)", error: true)
                return
            }
        }
        toast("已切换到 \(m.uppercased()) 模式")
        await refreshProxies()
    }

    func toggleTun() async {
        let target = !tunDisplayOn
        if !target, !passCooldown("关闭 TUN") { return }
        data.tunEnabled = target
        saveData()
        _ = generateConfig() // 同步落盘，保证之后的热重载/重启不回退 TUN 状态

        guard running else {
            toast("设置已保存，内核未运行，启动后生效")
            return
        }

        do {
            let tunObject = data.tun.mapValues { $0 } // 全量下发
            try await client.patchConfigs(["tun": Self.plainObject(tunObject)])
        } catch {
            toast("TUN 切换失败: \(error.localizedDescription)", error: true)
            return
        }

        // 验证 utun 网卡真实状态
        let verified = await Self.waitForTunState(expected: target)
        tunActive = await Self.tunInterfaceActive()
        if target && !verified {
            if privileged {
                toast("TUN 指令已下发但未检测到虚拟网卡，当前内核可能是提权前启动的，请重启内核一次", error: true)
            } else {
                toast("TUN 未能启用：内核没有 root 权限，请在「设置」中复制提权命令执行后重启内核", error: true)
            }
        } else {
            toast(target ? "TUN 已开启，系统流量已接管" : "TUN 已关闭")
        }
    }

    nonisolated static func plainObject(_ dict: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            switch v {
            case .string(let s): out[k] = s
            case .number(let n): out[k] = n.truncatingRemainder(dividingBy: 1) == 0 ? Int(n) : n
            case .bool(let b): out[k] = b
            case .null: out[k] = NSNull()
            case .array(let a): out[k] = a.map { plainAny($0) }
            case .object(let o): out[k] = plainObject(o)
            }
        }
        return out
    }

    nonisolated static func plainAny(_ v: JSONValue) -> Any {
        switch v {
        case .string(let s): return s
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? Int(n) : n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { plainAny($0) }
        case .object(let o): return plainObject(o)
        }
    }

    /// 通过检测 utun 网卡上的 TUN 地址(198.18.0.1) 判断 TUN 是否真正生效
    nonisolated static func tunInterfaceActive() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: text.contains("198.18.0.1"))
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    nonisolated static func waitForTunState(expected: Bool, timeout: TimeInterval = 3) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await tunInterfaceActive() == expected { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return await tunInterfaceActive() == expected
    }

    // ============ 节点来源 ============

    func addSubscription(name: String, url: String) async -> Bool {
        do {
            let parsed = try await SubscriptionParser.fetchAndParse(url)

            var fileName = SubscriptionParser.sanitizeFileName(name)
            let existing = data.sources.first { $0.name == fileName || $0.displayName == name }
            if let existing {
                fileName = existing.name
            } else {
                fileName = SubscriptionParser.resolveUniqueFileName(fileName, in: AppPaths.configsDir, sourceName: name)
            }

            try parsed.content.write(to: AppPaths.configsDir.appendingPathComponent(fileName),
                                     atomically: true, encoding: .utf8)

            let noneEnabled = !data.sources.contains { $0.enabled }
            if let idx = data.sources.firstIndex(where: { $0.name == fileName }) {
                data.sources[idx].displayName = name
                data.sources[idx].url = url
                data.sources[idx].format = parsed.format
                data.sources[idx].updatedAt = isoNow()
            } else {
                data.sources.append(Source(name: fileName, displayName: name, url: url,
                                           format: parsed.format, updatedAt: isoNow(),
                                           enabled: noneEnabled)) // 第一个来源自动启用
            }
            saveData()

            var note = ""
            if data.sources.first(where: { $0.name == fileName })?.enabled == true {
                note = await applyChanges().note
            }
            toast("订阅添加成功: \(fileName)\(note)")
            for w in parsed.warnings { toast("提示: \(w)") }
            return true
        } catch {
            toast("添加订阅失败: \(error.localizedDescription)", error: true)
            return false
        }
    }

    func updateSource(_ source: Source) async {
        guard let url = source.url, !url.isEmpty else {
            toast("本地导入的配置没有订阅地址，无法更新", error: true)
            return
        }
        toast("正在更新订阅: \(source.displayName)")
        do {
            let parsed = try await SubscriptionParser.fetchAndParse(url)
            try parsed.content.write(to: AppPaths.configsDir.appendingPathComponent(source.name),
                                     atomically: true, encoding: .utf8)
            if let idx = data.sources.firstIndex(where: { $0.name == source.name }) {
                data.sources[idx].updatedAt = isoNow()
                data.sources[idx].format = parsed.format
            }
            saveData()

            // 启用中且内核在运行：只刷新对应 provider，失败再退回整体热重载
            var note = ""
            if source.enabled && running {
                do {
                    try await client.refreshProxyProvider(ConfigGenerator.providerName(for: source.name))
                    note = "，节点已刷新"
                } catch {
                    note = await applyChanges().note
                }
            }
            toast("订阅更新成功: \(source.displayName)\(note)")
            for w in parsed.warnings { toast("提示: \(w)") }
            await refreshProxies()
        } catch {
            toast("更新订阅失败: \(error.localizedDescription)", error: true)
        }
    }

    func toggleSource(_ source: Source, enabled: Bool) async {
        guard let idx = data.sources.firstIndex(where: { $0.name == source.name }) else { return }
        data.sources[idx].enabled = enabled
        saveData()

        let apply = await applyChanges()
        if let error = apply.error {
            if !data.sources.contains(where: { $0.enabled }) {
                // 全部禁用时无法生成有效配置：状态已保存，运行中的内核继续用旧配置
                toast("已禁用: \(source.displayName)（\(error)）")
            } else {
                toast(error, error: true)
            }
        } else {
            toast("\(enabled ? "已启用" : "已禁用"): \(source.displayName)\(apply.note)")
        }
        await refreshProxies()
    }

    func deleteSource(_ source: Source) async {
        let wasEnabled = source.enabled
        data.sources.removeAll { $0.name == source.name }
        saveData()
        try? FileManager.default.removeItem(at: AppPaths.configsDir.appendingPathComponent(source.name))
        if wasEnabled {
            let apply = await applyChanges()
            if let error = apply.error { toast("已删除，但\(error)", error: true) } else { toast("已删除: \(source.displayName)\(apply.note)") }
        } else {
            toast("已删除: \(source.displayName)")
        }
    }

    func importLocalFile(from url: URL) async {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            switch SubscriptionParser.parse(content) {
            case .failure(let err):
                toast("导入失败: \(err.localizedDescription)", error: true)
            case .success(let parsed):
                let fileName = SubscriptionParser.sanitizeFileName(url.lastPathComponent)
                try parsed.content.write(to: AppPaths.configsDir.appendingPathComponent(fileName),
                                         atomically: true, encoding: .utf8)
                if let idx = data.sources.firstIndex(where: { $0.name == fileName }) {
                    data.sources[idx].updatedAt = isoNow()
                } else {
                    let noneEnabled = !data.sources.contains { $0.enabled }
                    data.sources.append(Source(name: fileName, displayName: url.lastPathComponent,
                                               url: nil, format: "local", updatedAt: isoNow(),
                                               enabled: noneEnabled))
                }
                saveData()
                var note = ""
                if data.sources.first(where: { $0.name == fileName })?.enabled == true {
                    note = await applyChanges().note
                }
                toast("已导入: \(fileName)\(note)")
                for w in parsed.warnings { toast("提示: \(w)") }
            }
        } catch {
            toast("导入失败: \(error.localizedDescription)", error: true)
        }
    }

    // ============ 规则 ============

    func saveRules(text: String, finalTarget: String) async {
        saveRulesText(text)
        if FINAL_TARGETS.contains(finalTarget) {
            data.finalTarget = finalTarget
            saveData()
        }
        let apply = await applyChanges()
        if let error = apply.error {
            toast(error, error: true)
        } else {
            toast("规则已保存\(apply.note)")
        }
    }

    // ============ 远程规则集 ============

    struct RuleProviderForm {
        var name = ""
        var url = ""
        var behavior = "auto"
        var format = "auto"
        var target = "PROXY"
        var targetKind = "builtin"
        var viaProxy = true
    }

    /// 规则目标选择器中可用的策略组；固定目标单独展示，避免重复。
    var ruleTargetGroups: [String] {
        let fixed = Set(FINAL_TARGETS)
        let names = proxies.compactMap { name, proxy in
            proxy.isGroup && proxy.hidden != true
                && !name.hasPrefix("__MIDOG_RULE_NODE_")
                && !fixed.contains(name)
                && normalizedRuleTarget(name) != nil ? name : nil
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// provider 节点不一定出现在 /proxies 顶层，从所有策略组的成员中一并收集。
    var ruleTargetNodes: [String] {
        let groupNames = Set(proxies.compactMap { $0.value.isGroup ? $0.key : nil })
        let reserved = Set(FINAL_TARGETS + ["GLOBAL", "PASS", "COMPATIBLE"])
        var names = Set<String>()
        for proxy in proxies.values {
            for name in proxy.all ?? [] where !groupNames.contains(name)
                && !reserved.contains(name) && normalizedRuleTarget(name) != nil {
                names.insert(name)
            }
        }
        for (name, proxy) in proxies where !proxy.isGroup
            && !reserved.contains(name) && normalizedRuleTarget(name) != nil {
            names.insert(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func addRuleProvider(_ form: RuleProviderForm) async -> Bool {
        let name = form.name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        let url = form.url.trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty, name.range(of: "^_+$", options: .regularExpression) == nil else {
            toast("名称无效（仅支持字母/数字/._-）", error: true)
            return false
        }
        guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else {
            toast("URL 必须以 http:// 或 https:// 开头", error: true)
            return false
        }

        var behavior = RULE_BEHAVIORS.contains(form.behavior) ? form.behavior : nil
        var format = RULE_FORMATS.contains(form.format) ? form.format : nil
        var converted = false
        var sourceFormat: String?
        var ruleCount: Int?
        var convertedText: String?

        if format == "mrs" || url.range(of: "\\.mrs([?#]|$)", options: [.regularExpression, .caseInsensitive]) != nil {
            // mrs 为二进制格式，不做内容分析；行为按 URL 猜测，可手动指定覆盖
            format = "mrs"
            if behavior == nil {
                behavior = url.range(of: "\\b(ip|cidr)", options: [.regularExpression, .caseInsensitive]) != nil ? "ipcidr" : "domain"
            }
        } else {
            do {
                let raw = try await SubscriptionParser.download(url)
                switch RulesetParser.analyze(raw) {
                case .failure(let err):
                    toast("规则内容无法识别: \(err.localizedDescription)", error: true)
                    return false
                case .success(let analysis):
                    ruleCount = analysis.ruleCount
                    if analysis.converted {
                        // base64/gfwlist 等 mihomo 不认的内容：转换后由 App 写入本地文件提供
                        converted = true
                        sourceFormat = analysis.sourceFormat
                        behavior = analysis.behavior
                        format = analysis.format
                        convertedText = analysis.text
                    } else {
                        behavior = behavior ?? analysis.behavior
                        format = format ?? analysis.format
                    }
                }
            } catch {
                // 直连下载失败：手动指定了类型和格式时仍可保存，交给 mihomo（可走代理）下载
                if behavior == nil || format == nil {
                    toast("下载规则失败，无法自动识别: \(error.localizedDescription)（可手动指定类型/格式后重试）", error: true)
                    return false
                }
            }
        }

        let provider = RuleProvider(
            name: name, url: url,
            behavior: behavior ?? "classical",
            format: format ?? "yaml",
            converted: converted,
            sourceFormat: sourceFormat,
            target: normalizedRuleTarget(form.target) ?? "PROXY",
            targetKind: RULE_TARGET_KINDS.contains(form.targetKind) ? form.targetKind : "builtin",
            interval: 86400,
            viaProxy: form.viaProxy,
            enabled: true,
            convertedUpdatedAt: converted ? isoNow() : nil
        )

        // 转换产物先落盘，mihomo 加载配置时直接读取
        if converted, let text = convertedText {
            let cache = AppPaths.ruleProvidersDir.appendingPathComponent(provider.name + provider.fileExtension)
            do {
                try text.write(to: cache, atomically: true, encoding: .utf8)
            } catch {
                toast("写入转换后的规则文件失败: \(error.localizedDescription)", error: true)
                return false
            }
        }

        if let idx = data.ruleProviders.firstIndex(where: { $0.name == name }) {
            data.ruleProviders[idx] = provider // 整体替换，避免旧的 converted 等字段残留
        } else {
            data.ruleProviders.append(provider)
        }
        saveData()

        // 热重载时 mihomo 会立即加载该规则集，下载/解析失败会在此报错
        let apply = await applyChanges()
        if let error = apply.error {
            toast(error, error: true)
            return false
        }
        let detected = converted
            ? "（\(sourceFormat ?? "") 已转换, \(ruleCount ?? 0) 条）"
            : (ruleCount != nil ? "（\(provider.behavior)/\(provider.format), \(ruleCount!) 条）" : "")
        toast("规则集已添加: \(name)\(detected)\(apply.note)")
        await refreshRuleRuntime()
        return true
    }

    /// 导入本地规则集并复制到 App 数据目录，避免依赖原文件后续是否仍然存在。
    func importLocalRuleProvider(from sourceURL: URL) async {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let originalName = sourceURL.lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        var baseName = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        if baseName.isEmpty { baseName = "ruleset" }
        let name = uniqueRuleProviderName(baseName)

        do {
            let provider: RuleProvider
            let cachedURL: URL
            if ext == "mrs" {
                let behavior = originalName.range(of: "(^|[._-])(ip|cidr)([._-]|$)",
                                                   options: [.regularExpression, .caseInsensitive]) != nil
                    ? "ipcidr" : "domain"
                cachedURL = AppPaths.ruleProvidersDir.appendingPathComponent(name + ".mrs")
                try Data(contentsOf: sourceURL).write(to: cachedURL, options: .atomic)
                provider = RuleProvider(
                    name: name, url: "local://\(originalName)", behavior: behavior,
                    format: "mrs", converted: true, sourceFormat: "local-mrs",
                    target: "PROXY", interval: 86400, viaProxy: false, enabled: true,
                    convertedUpdatedAt: isoNow())
            } else {
                let raw = try String(contentsOf: sourceURL, encoding: .utf8)
                let analysis: RulesetParser.Analysis
                switch RulesetParser.analyze(raw) {
                case .failure(let error):
                    toast("导入规则集失败: \(error.localizedDescription)", error: true)
                    return
                case .success(let result):
                    analysis = result
                }
                let fileExtension = analysis.format == "text" ? ".txt" : ".yaml"
                cachedURL = AppPaths.ruleProvidersDir.appendingPathComponent(name + fileExtension)
                try analysis.text.write(to: cachedURL, atomically: true, encoding: .utf8)
                provider = RuleProvider(
                    name: name, url: "local://\(originalName)", behavior: analysis.behavior,
                    format: analysis.format, converted: true,
                    sourceFormat: "local-\(analysis.sourceFormat)", target: "PROXY",
                    interval: 86400, viaProxy: false, enabled: true,
                    convertedUpdatedAt: isoNow())
            }

            data.ruleProviders.append(provider)
            saveData()
            let apply = await applyChanges()
            if let error = apply.error {
                data.ruleProviders.removeAll { $0.name == name }
                saveData()
                try? FileManager.default.removeItem(at: cachedURL)
                _ = generateConfig()
                toast("导入规则集失败: \(error)", error: true)
            } else {
                toast("已导入本地规则集: \(name)\(apply.note)")
            }
            await refreshRuleRuntime()
        } catch {
            toast("导入规则集失败: \(error.localizedDescription)", error: true)
        }
    }

    private func uniqueRuleProviderName(_ baseName: String) -> String {
        let existing = Set(data.ruleProviders.map(\.name))
        if !existing.contains(baseName) { return baseName }
        var suffix = 2
        while existing.contains("\(baseName)-\(suffix)") { suffix += 1 }
        return "\(baseName)-\(suffix)"
    }

    /// 修改已有规则文件的出站目标，失败时恢复原值，避免持久化数据与运行配置不一致。
    func updateRuleProviderTarget(_ provider: RuleProvider, target rawTarget: String, kind: String) async {
        guard let target = normalizedRuleTarget(rawTarget) else {
            toast("规则目标无效", error: true)
            return
        }
        guard RULE_TARGET_KINDS.contains(kind) else {
            toast("规则目标类型无效", error: true)
            return
        }
        guard let idx = data.ruleProviders.firstIndex(where: { $0.name == provider.name }) else { return }
        let previous = data.ruleProviders[idx].target
        let previousKind = data.ruleProviders[idx].targetKind
        guard previous != target || previousKind != kind else { return }

        data.ruleProviders[idx].target = target
        data.ruleProviders[idx].targetKind = kind
        saveData()
        let apply = await applyChanges()
        if let error = apply.error {
            data.ruleProviders[idx].target = previous
            data.ruleProviders[idx].targetKind = previousKind
            saveData()
            _ = generateConfig()
            toast("切换规则目标失败，已恢复为 \(previous)：\(error)", error: true)
        } else {
            toast("\(provider.name) 命中后走 \(target)\(apply.note)")
        }
    }

    func toggleRuleProvider(_ provider: RuleProvider, enabled: Bool) async {
        guard let idx = data.ruleProviders.firstIndex(where: { $0.name == provider.name }) else { return }
        data.ruleProviders[idx].enabled = enabled
        saveData()
        let apply = await applyChanges()
        if let error = apply.error {
            toast(error, error: true)
        } else {
            toast("\(enabled ? "已启用规则集" : "已禁用规则集"): \(provider.name)\(apply.note)")
        }
        await refreshRuleRuntime()
    }

    func refreshRuleProvider(_ provider: RuleProvider) async {
        toast("正在刷新规则集: \(provider.name)")
        if provider.converted && !provider.isLocal {
            // 转换型：重新拉取上游 → 转换 → 落盘，再让内核重读文件
            do {
                let raw = try await SubscriptionParser.download(provider.url)
                switch RulesetParser.analyze(raw) {
                case .failure(let err):
                    toast("上游规则拉取/转换失败: \(err.localizedDescription)", error: true)
                    return
                case .success(let analysis):
                    let cache = AppPaths.ruleProvidersDir.appendingPathComponent(provider.name + provider.fileExtension)
                    try analysis.text.write(to: cache, atomically: true, encoding: .utf8)
                    if let idx = data.ruleProviders.firstIndex(where: { $0.name == provider.name }) {
                        data.ruleProviders[idx].convertedUpdatedAt = isoNow()
                        saveData()
                    }
                }
            } catch {
                toast("上游规则拉取失败: \(error.localizedDescription)", error: true)
                return
            }
        }
        guard running else {
            toast(provider.converted ? "规则集已刷新（内核未运行）" : "内核未运行，无法刷新", error: !provider.converted)
            return
        }
        do {
            let code = try await client.refreshRuleProvider(provider.name)
            if code == 404 {
                // 运行配置里还没有它（如刚启用未重载）→ 整体热重载兜底
                let apply = await applyChanges()
                if let error = apply.error {
                    toast(error, error: true)
                    return
                }
            }
            toast("规则集已刷新: \(provider.name)")
            await refreshRuleRuntime()
        } catch {
            toast("刷新失败: \(error.localizedDescription)", error: true)
        }
    }

    func deleteRuleProvider(_ provider: RuleProvider) async {
        let wasEnabled = provider.enabled
        data.ruleProviders.removeAll { $0.name == provider.name }
        saveData()
        // 清理下载/转换缓存
        for ext in [".yaml", ".txt", ".mrs"] {
            try? FileManager.default.removeItem(at: AppPaths.ruleProvidersDir.appendingPathComponent(provider.name + ext))
        }
        if wasEnabled {
            let apply = await applyChanges()
            if let error = apply.error { toast("已删除，但\(error)", error: true) } else { toast("已删除规则集: \(provider.name)\(apply.note)") }
        } else {
            toast("已删除规则集: \(provider.name)")
        }
        await refreshRuleRuntime()
    }

    /// 转换型规则集按 interval 定期重新拉取上游（旧版靠 mihomo 回源本地 HTTP 服务实现）
    func refreshStaleConvertedProviders() async {
        let formatter = ISO8601DateFormatter()
        for provider in data.ruleProviders where provider.converted && !provider.isLocal && provider.enabled {
            let last = provider.convertedUpdatedAt.flatMap { formatter.date(from: $0) } ?? .distantPast
            if Date().timeIntervalSince(last) > Double(max(provider.interval, 3600)) {
                await refreshRuleProvider(provider)
            }
        }
    }

    /// 内核刚起来时 API 还没就绪，重试几次直到能读到规则集运行时状态。
    private func verifyMandatoryAfterStart() async {
        for _ in 0..<10 {
            guard running else { return }
            if (try? await client.ruleProvidersRuntime()) != nil {
                await refreshRuleRuntime()
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func refreshRuleRuntime() async {
        guard running else {
            ruleRuntime = [:]
            return
        }
        if let runtime = try? await client.ruleProvidersRuntime() {
            ruleRuntime = runtime
        }
        await enforceRuntimeIntegrity()
    }

    /// 内核运行时完整性校验（每次轮询都跑）：external-controller 的 API 能 PUT /configs 换掉整份配置、
    /// PATCH 关掉 TUN，也能有人直接改缓存文件。任一项对不上就用 App 生成的配置热重载回来。
    /// ponytail: 只看强制规则集 / 第一条规则 / TUN 三个信号；能读 config.yaml 里 secret 的本机用户
    /// 仍可构造一份"看起来一样"的配置，彻底防住需要 root 守护进程持有密钥。
    private func enforceRuntimeIntegrity() async {
        guard running, let runtime = try? await client.ruleProvidersRuntime() else { return }
        ruleRuntime = runtime
        var reasons: [String] = []
        for item in MANDATORY_RULE_PROVIDERS {
            let name = item.provider.name
            let cache = AppPaths.ruleProvidersDir.appendingPathComponent(name + item.provider.fileExtension)
            if ConfigGenerator.sha256(of: cache) != item.bundledSHA256 {
                reasons.append("\(name) 缓存文件被改动")
            }
            let count = runtime[name]?.ruleCount ?? 0
            if count < item.minimumRuleCount {
                reasons.append("\(name) 只加载到 \(count) 条")
            }
        }
        let expectedFirst = MANDATORY_RULE_PROVIDERS.first.map { "RuleSet,\($0.provider.name),REJECT" }
        if let expectedFirst, let first = try? await client.firstRule(), first != expectedFirst {
            reasons.append("第一条规则变成了 \(first)")
        }
        if data.tunEnabled && privileged && !tunActive {
            reasons.append("TUN 被外部关闭")
        }
        guard !reasons.isEmpty else { return }
        // 恢复失败（比如包内副本本身坏了）时别每 3 秒重载一次
        if let last = lastIntegrityRepair, Date().timeIntervalSince(last) < 30 { return }
        lastIntegrityRepair = Date()
        let summary = reasons.joined(separator: "；")
        let apply = await applyChanges() // generateConfig 内会按哈希恢复缓存
        if let error = apply.error {
            appendLog(.system, "检测到 \(summary)，恢复失败: \(error)")
            return
        }
        if data.tunEnabled && privileged && !tunActive {
            try? await client.patchConfigs(["tun": Self.plainObject(data.tun)])
        }
        appendLog(.system, "检测到 \(summary)，已恢复为 App 生成的配置")
        toast("检测到拦截规则被篡改，已自动恢复", error: true)
    }

    // ============ 系统设置 ============

    var settingsJSONText: String {
        let obj: JSONValue = .object([
            "settings": .object(data.settings.filter { $0.key != "secret" }), // 密钥不展示
            "dns": .object(data.dns),
            "hosts": .object(data.hosts)
        ])
        // 用 JSONSerialization 输出带缩进的稳定 JSON
        let plain = Self.plainObject(obj.objectValue ?? [:])
        if let d = try? JSONSerialization.data(withJSONObject: plain, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    func saveSettingsJSON(_ text: String) async -> Bool {
        guard let rawData = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: rawData) else {
            toast("JSON 格式错误，请检查后重试", error: true)
            return false
        }
        if let s = decoded["settings"]?.objectValue {
            let allowed = s.filter { ALLOWED_SETTINGS_KEYS.contains($0.key) && $0.key != "secret" }
            let dropped = s.keys.filter { allowed[$0] == nil && $0 != "secret" }
            if !dropped.isEmpty {
                toast("已忽略不支持的设置项: \(dropped.sorted().joined(separator: ", "))", error: true)
            }
            data.settings = data.settings.merging(allowed) { _, new in new }
            data.settings["mode"] = .string(LOCKED_MODE) // 从 JSON 里也改不动出站模式
        }
        if let d = decoded["dns"]?.objectValue {
            data.dns = d
        }
        if let h = decoded["hosts"]?.objectValue {
            data.hosts = h
        }
        saveData()
        let apply = await applyChanges()
        if let error = apply.error {
            toast(error, error: true)
            return false
        }
        toast("设置已保存\(apply.note)")
        return true
    }

    // ============ 节点 / 延迟 ============

    func refreshProxies() async {
        guard running else {
            connected = false
            proxies = [:]
            return
        }
        do {
            proxies = try await client.proxies()
            if !connected {
                connected = true
                if let v = try? await client.version() { coreVersion = v }
                startTrafficStream()
                startLogStream()
            }
            if trafficTask == nil { startTrafficStream() }
            if logTask == nil { startLogStream() }
        } catch {
            connected = false
            stopLogStream()
        }
    }

    func selectProxy(group: String, name: String) async {
        do {
            try await client.selectProxy(group: group, name: name)
            if var g = proxies[group] {
                g.now = name
                proxies[group] = g
            }
            toast("已切换到 \(name)")
            Task { await self.testDelay(name) }
        } catch {
            toast("切换节点失败: \(error.localizedDescription)", error: true)
        }
    }

    func testDelay(_ name: String) async {
        delays[name] = .testing
        delays[name] = await measureDelay(name)
    }

    /// 测一个出站的延迟并把结果返回（不写进 delays），供出口自检复用
    func measureDelay(_ name: String) async -> DelayState {
        do {
            return .ms(try await client.delay(proxy: name))
        } catch ControllerError.http(404, _) {
            // provider 内的节点不在顶层 /proxies 里，/proxies/{name}/delay 恒 404，
            // 改走 /providers/proxies/{provider}/{name}/healthcheck
            return await providerNodeDelay(name)
        } catch {
            return Self.delayState(for: error)
        }
    }

    /// 在启用的来源 provider 里逐个找该节点测速（404 = 不在该 provider，继续找下一个）
    private func providerNodeDelay(_ name: String) async -> DelayState {
        for src in data.sources where src.enabled {
            let provider = ConfigGenerator.providerName(for: src.name)
            do {
                return .ms(try await client.providerHealthcheck(provider: provider, proxy: name))
            } catch ControllerError.http(404, _) {
                continue
            } catch {
                return Self.delayState(for: error)
            }
        }
        return .failed("未在任何节点来源中找到该节点")
    }

    private static func delayState(for error: Error) -> DelayState {
        if case ControllerError.http(408, _) = error { return .timeout }
        return .failed(error.localizedDescription)
    }

    /// 优先用 /group/{name}/delay 一次测完全组；不可用时退回逐个并发测试
    func testAllDelays(group groupName: String) async {
        guard let group = proxies[groupName], let all = group.all, !all.isEmpty else { return }
        testingAll = true
        defer { testingAll = false }

        for name in all { delays[name] = .testing }

        if let result = try? await client.groupDelay(group: groupName) {
            for name in all {
                delays[name] = result[name].map { .ms($0) } ?? .timeout
            }
            await refreshProxies()
            toast("延迟测试完成")
            return
        }

        // 回退：跳过子分组，5 个一批并发
        let targets = all.filter { !(proxies[$0]?.isGroup ?? false) }
        for name in all where !targets.contains(name) { delays[name] = .failed("子分组不参与逐个测速") }
        for batch in stride(from: 0, to: targets.count, by: 5).map({ Array(targets[$0..<min($0 + 5, targets.count)]) }) {
            await withTaskGroup(of: Void.self) { taskGroup in
                for name in batch {
                    taskGroup.addTask { await self.testDelay(name) }
                }
            }
        }
        toast("延迟测试完成")
    }

    /// 当前路由链：GROUP → GROUP → 节点
    var routePath: [String] {
        if data.mode == "direct" { return ["DIRECT"] }
        var path: [String] = []
        var current = activeGroupName
        var visited = Set<String>()
        while !visited.contains(current), let group = proxies[current] {
            visited.insert(current)
            path.append(current)
            guard let selected = group.now, !selected.isEmpty else { break }
            if let next = proxies[selected], next.isGroup {
                current = selected
            } else {
                path.append(selected)
                break
            }
        }
        return path
    }

    var currentProxyName: String? {
        if data.mode == "direct" { return nil }
        return routePath.last.flatMap { proxies[$0] == nil || !(proxies[$0]!.isGroup) ? $0 : nil }
    }

    // ============ 后台轮询 ============

    func runLoops() async {
        await bootstrapKernel()
        Task { await refreshStaleConvertedProviders() }
        while !Task.isCancelled {
            await pollTick()
            // 旧版的绑定可能已在内核运行、磁盘配置却已更新；以实际出站为准。
            if connected, proxies["DIRECT-WIFI"]?.type?.lowercased() == "direct",
               lastLegacyRoutingRepair.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
                lastLegacyRoutingRepair = Date()
                let result = await applyChanges()
                if let error = result.error {
                    toast("移除旧出口分流配置失败：\(error)", error: true)
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func pollTick() async {
        let servicePID = await Task.detached { CoreService.pid() }.value
        if servicePID != pid {
            if let servicePID {
                appendLog(.system, "launchd 内核运行中, PID: \(servicePID)")
                startedAt = Date()
                startupError = nil
                Task { await verifyMandatoryAfterStart() }
            } else if pid != nil {
                appendLog(.system, "内核进程已退出，等待 launchd 重新启动")
                startedAt = nil
                connected = false
                stopTrafficStream()
                stopLogStream()
            }
        }
        pid = servicePID
        running = servicePID != nil
        privileged = CoreService.installed
        tunActive = await Self.tunInterfaceActive()
        await refreshProxies()
        if connected {
            await enforceLockedMode()
            await enforceRuntimeIntegrity()
            if let snapshot = try? await client.connections() {
                connCount = snapshot.count
                totalUp = snapshot.uploadTotal
                totalDown = snapshot.downloadTotal
            }
            scheduleCurrentRouteDelayTestIfNeeded()
        } else {
            connCount = 0
        }
    }

    /// 出站模式的锁定只在 App 这一层（data.json / 生成的配置）生效：内核的 external-controller
    /// REST API 本身不认这个约束，任何知道 API 地址（默认 127.0.0.1:9090）和 secret 的人都能
    /// 直接 `PATCH /configs {"mode":"global"}` 把内核切到 global/direct，让 rules（含内置的
    /// 强制成人内容拦截）整段失效，且 App 界面上完全看不出来。
    /// 这里每次轮询主动读回内核的真实 mode 并纠正，把绕过窗口压到一次轮询间隔（3 秒）内，
    /// 而不是直到下次重启/热重载才发现。
    private func enforceLockedMode() async {
        guard running, let live = try? await client.currentMode(), !live.isEmpty else { return }
        guard live != LOCKED_MODE else { return }
        do {
            try await client.patchConfigs(["mode": LOCKED_MODE])
            appendLog(.system, "检测到出站模式被外部改为 \(live.uppercased())（可能是绕过锁定的 API 调用），已强制恢复为 \(LOCKED_MODE.uppercased())")
            toast("检测到出站模式被外部修改，已自动恢复锁定", error: true)
        } catch {
            appendLog(.system, "出站模式被改为 \(live.uppercased())，恢复失败: \(error.localizedDescription)")
        }
    }

    private func scheduleCurrentRouteDelayTestIfNeeded() {
        guard let name = currentProxyName else { return }
        if delays[name] == .testing { return }

        let now = Date()
        let shouldTest: Bool
        if delays[name] == nil {
            shouldTest = true
        } else if let last = lastAutoDelayTestAt[name] {
            shouldTest = now.timeIntervalSince(last) >= currentRouteDelayRefreshInterval
        } else {
            lastAutoDelayTestAt[name] = now
            shouldTest = false
        }

        guard shouldTest else { return }
        lastAutoDelayTestAt[name] = now
        delays[name] = .testing
        Task { [weak self] in
            await self?.testDelay(name)
        }
    }

    private func startTrafficStream() {
        guard trafficTask == nil else { return }
        let client = self.client
        trafficTask = Task { [weak self] in
            do {
                let (bytes, _) = try await client.trafficStream()
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { break }
                    guard let d = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    let up = (obj["up"] as? Int) ?? 0
                    let down = (obj["down"] as? Int) ?? 0
                    await MainActor.run {
                        guard let self else { return }
                        self.upRate = up
                        self.downRate = down
                        self.upHistory.append(Double(up))
                        self.downHistory.append(Double(down))
                        if self.upHistory.count > 60 { self.upHistory.removeFirst() }
                        if self.downHistory.count > 60 { self.downHistory.removeFirst() }
                    }
                }
            } catch { /* 连接断开由轮询重建 */ }
            await MainActor.run {
                guard let self else { return }
                self.trafficTask = nil
                self.upRate = 0
                self.downRate = 0
            }
        }
    }

    private func stopTrafficStream() {
        trafficTask?.cancel()
        trafficTask = nil
        upRate = 0
        downRate = 0
        upHistory = []
        downHistory = []
    }

    private func startLogStream() {
        guard logTask == nil else { return }
        let client = self.client
        logTask = Task { [weak self] in
            do {
                let (bytes, _) = try await client.logStream()
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { break }
                    guard let data = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                          let message = object["payload"] else { continue }
                    self?.appendLog(object["type"] == "error" ? .error : .info, message)
                }
            } catch { /* 下次轮询重连 */ }
            self?.logTask = nil
        }
    }

    private func stopLogStream() {
        logTask?.cancel()
        logTask = nil
    }

    // ============ UI 工具 ============

    func toast(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toasts.append(t)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        Task {
            try? await Task.sleep(nanoseconds: error ? 6_000_000_000 : 3_500_000_000)
            toasts.removeAll { $0.id == t.id }
        }
    }

}
