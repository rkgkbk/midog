import Foundation
import AppKit
import Combine

enum DelayState: Equatable {
    case testing
    case ms(Int)
    case failed

    var text: String {
        switch self {
        case .testing: return "…"
        case .ms(let v): return "\(v) ms"
        case .failed: return "超时"
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

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // ---- 持久数据 ----
    @Published var data: AppData
    @Published var rulesText: String
    @Published var kernelPath: String {
        didSet { UserDefaults.standard.set(kernelPath, forKey: "kernelPath") }
    }
    @Published var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStartCore") }
    }

    // ---- 运行状态 ----
    @Published var running = false
    @Published var pid: Int32?
    @Published var connected = false            // external-controller 可达
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
    @Published var busy = false                 // 进程启停中
    @Published var startupError: String?        // 启动失败/异常退出的常驻错误横幅

    // ---- UI ----
    @Published var toasts: [Toast] = []

    private let core = CoreProcess()
    private var trafficTask: Task<Void, Never>?
    private var stopRequested = false           // 区分用户主动停止与异常退出
    private let maxLogs = 500

    var client: ControllerClient {
        ControllerClient(controller: data.externalController, secret: data.secret)
    }

    var tunSetupCommand: String {
        "sudo chown root:admin '\(kernelPath)' && sudo chmod u+s '\(kernelPath)'"
    }

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
        kernelPath = UserDefaults.standard.string(forKey: "kernelPath") ?? AppPaths.detectKernel() ?? ""
        autoStart = UserDefaults.standard.bool(forKey: "autoStartCore")
        data.syncLocalFiles(configsDir: AppPaths.configsDir)
        privileged = Self.binaryPrivileged(kernelPath)

        core.onLog = { [weak self] level, message in
            self?.appendLog(level, message)
        }
        core.onExit = { [weak self] code in
            guard let self else { return }
            let uptime = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.running = false
            self.pid = nil
            self.startedAt = nil
            self.connected = false
            self.stopTrafficStream()

            if self.stopRequested {
                self.stopRequested = false
                return
            }
            // 非用户主动停止：把退出原因显式暴露出来，而不是让 UI 静默弹回
            let errLines = self.logs.suffix(30)
                .filter { $0.level == .error }
                .suffix(3)
                .map { $0.message }
                .joined(separator: "\n")
            if uptime < 15 {
                self.startupError = "内核启动后异常退出 (code \(code))"
                    + (errLines.isEmpty ? "" : "：\n\(errLines)")
            } else {
                self.toast("内核已意外退出 (code \(code))", error: true)
            }
        }
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

    // ============ 进程控制 ============

    func startCore() async {
        guard !running else {
            toast("mihomo 已在运行中", error: true)
            return
        }
        guard !kernelPath.isEmpty else {
            toast("请先在「设置」中选择 mihomo 内核文件", error: true)
            return
        }
        busy = true
        defer { busy = false }

        if let error = generateConfig() {
            toast(error, error: true)
            return
        }

        // 端口预检：mihomo 端口被占用时不会退出，而是变成不监听任何端口的僵尸进程，
        // 且本应用会误连到占用者(如旧版实例)的 API —— 必须在启动前拦截
        let conflicts = portConflicts()
        if !conflicts.isEmpty {
            let holders = Self.listeningCommands(ports: conflicts)
            let holderNote = holders.isEmpty ? "" : "（占用进程: \(holders)）"
            startupError = "无法启动内核：端口 \(conflicts.map(String.init).joined(separator: ", ")) 已被占用\(holderNote)。"
                + "旧版 web 实例可能仍在运行，请先停止它（pm2 stop mihomo-server），或在「设置」中修改本应用的端口。"
            toast("端口被占用，内核未启动", error: true)
            return
        }

        do {
            let newPid = try core.start(binaryPath: kernelPath, dataDir: AppPaths.dataDir)
            running = true
            pid = newPid
            startedAt = Date()
            startupError = nil
            stopRequested = false
            appendLog(.system, "内核已启动, PID: \(newPid)")
            toast("mihomo 已启动")
            // 转换型规则集若超期，启动后顺手刷新
            Task { await refreshStaleConvertedProviders() }
        } catch {
            toast(error.localizedDescription, error: true)
        }
    }

    func stopCore() async {
        guard running else {
            toast("mihomo 未运行", error: true)
            return
        }
        busy = true
        defer { busy = false }
        stopRequested = true
        await core.stop()
        running = false
        pid = nil
        startedAt = nil
        connected = false
        stopTrafficStream()
        proxies = [:]
        connCount = 0
        upRate = 0
        downRate = 0
        toast("mihomo 已停止")
    }

    /// 重启：真正等待旧进程退出，而不是旧版的固定 sleep
    func restartCore() async {
        busy = true
        stopRequested = true
        await core.stop()
        running = false
        connected = false
        stopTrafficStream()
        busy = false
        await startCore()
    }

    func shutdownForQuit() {
        stopRequested = true
        core.terminateNow()
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

    /// 用 lsof 找出监听这些端口的进程名（尽力而为，失败返回空）
    nonisolated static func listeningCommands(ports: [Int]) -> String {
        guard !ports.isEmpty else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP"] + ports.map { "-iTCP:\($0)" } + ["-sTCP:LISTEN", "-Fc"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ""
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("c") {
            let name = String(line.dropFirst())
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ", ")
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
        data.tunEnabled = target
        saveData()
        _ = generateConfig() // 同步落盘，保证之后的热重载/重启不回退 TUN 状态

        guard running else {
            toast("设置已保存，mihomo 未运行，启动后生效")
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

    nonisolated static func binaryPrivileged(_ path: String) -> Bool {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return owner == 0 && (perms & 0o4000) != 0
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
        var viaProxy = true
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
            target: FINAL_TARGETS.contains(form.target) ? form.target : "PROXY",
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
        if provider.converted {
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
        for provider in data.ruleProviders where provider.converted && provider.enabled {
            let last = provider.convertedUpdatedAt.flatMap { formatter.date(from: $0) } ?? .distantPast
            if Date().timeIntervalSince(last) > Double(max(provider.interval, 3600)) {
                await refreshRuleProvider(provider)
            }
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
    }

    // ============ 系统设置 ============

    var settingsJSONText: String {
        let obj: JSONValue = .object([
            "settings": .object(data.settings),
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
            data.settings = data.settings.merging(s) { _, new in new }
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
            }
        } catch {
            connected = false
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
        do {
            let ms = try await client.delay(proxy: name)
            delays[name] = .ms(ms)
        } catch {
            delays[name] = .failed
        }
    }

    /// 优先用 /group/{name}/delay 一次测完全组；不可用时退回逐个并发测试
    func testAllDelays(group groupName: String) async {
        guard let group = proxies[groupName], let all = group.all, !all.isEmpty else { return }
        testingAll = true
        defer { testingAll = false }

        for name in all { delays[name] = .testing }

        if let result = try? await client.groupDelay(group: groupName) {
            for name in all {
                delays[name] = result[name].map { .ms($0) } ?? .failed
            }
            await refreshProxies()
            toast("延迟测试完成")
            return
        }

        // 回退：跳过子分组，5 个一批并发
        let targets = all.filter { !(proxies[$0]?.isGroup ?? false) }
        for name in all where !targets.contains(name) { delays[name] = .failed }
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
        if autoStart && !running && data.sources.contains(where: { $0.enabled }) {
            await startCore()
        }
        Task { await refreshStaleConvertedProviders() }
        while !Task.isCancelled {
            await pollTick()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func pollTick() async {
        running = core.isRunning
        pid = core.pid
        privileged = Self.binaryPrivileged(kernelPath)
        tunActive = await Self.tunInterfaceActive()
        await refreshProxies()
        if connected {
            if let snapshot = try? await client.connections() {
                connCount = snapshot.count
                totalUp = snapshot.uploadTotal
                totalDown = snapshot.downloadTotal
            }
        } else {
            connCount = 0
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

    // ============ 旧版数据迁移 ============

    /// 从旧版 Node 项目的 data 目录导入 data.json / rules.txt / configs / rule-providers / geo 数据库
    func importLegacyData(from dir: URL) {
        let fm = FileManager.default
        let legacyDataFile = dir.appendingPathComponent("data.json")
        guard fm.fileExists(atPath: legacyDataFile.path) else {
            toast("所选目录中没有 data.json，请选择旧项目的 data 目录", error: true)
            return
        }

        func copyReplacing(_ from: URL, _ to: URL) {
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: from, to: to)
        }

        copyReplacing(legacyDataFile, AppPaths.dataFile)
        let legacyRules = dir.appendingPathComponent("rules.txt")
        if fm.fileExists(atPath: legacyRules.path) {
            copyReplacing(legacyRules, AppPaths.rulesFile)
        }
        for sub in ["configs", "rule-providers"] {
            let src = dir.appendingPathComponent(sub)
            guard let files = try? fm.contentsOfDirectory(atPath: src.path) else { continue }
            let dst = sub == "configs" ? AppPaths.configsDir : AppPaths.ruleProvidersDir
            for f in files {
                copyReplacing(src.appendingPathComponent(f), dst.appendingPathComponent(f))
            }
        }
        // geo 数据库与 fake-ip 缓存
        if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasSuffix(".mmdb") || f.hasSuffix(".metadb") || f.hasSuffix(".dat") || f == "cache.db" {
                copyReplacing(dir.appendingPathComponent(f), AppPaths.dataDir.appendingPathComponent(f))
            }
        }

        data = Self.loadData()
        rulesText = Self.loadRulesText()
        data.syncLocalFiles(configsDir: AppPaths.configsDir)
        saveData()
        _ = generateConfig()
        toast("旧版数据导入完成：\(data.sources.count) 个来源、\(data.ruleProviders.count) 个规则集")
    }

    /// 检测旧版数据目录（用于首次启动引导）
    var legacyDataDirCandidate: URL? {
        guard data.sources.isEmpty else { return nil }
        let candidate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mm/data")
        return FileManager.default.fileExists(atPath: candidate.appendingPathComponent("data.json").path) ? candidate : nil
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

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast("已复制到剪贴板")
    }
}
