import Foundation

/// 独立于 UI 和代理内核的 launchd 系统服务。
nonisolated enum WatchdogService {
    static let label = "com.xx.midog.watchdog"
    static let directory = "/Library/Application Support/midog-watchdog"
    static let binary = directory + "/midog-watchdog"
    static let rulesPath = directory + "/proxies.list"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static var installed: Bool { FileManager.default.fileExists(atPath: plist) }

    static var bundledBinary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/midog-watchdog")
    }

    static func rules() throws -> String {
        if installed { return try String(contentsOfFile: rulesPath, encoding: .utf8) }
        guard let url = Bundle.main.url(forResource: "proxies", withExtension: "list") else {
            throw Privileged.Failure.failed("安装包缺少代理名单")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func job() -> [String: Any] {
        ["Label": label, "ProgramArguments": [binary], "RunAtLoad": true,
         "KeepAlive": true, "ThrottleInterval": 10,
         "ProcessType": "Background", "UserName": "root",
         "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
    }

    static func status() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "无法查询服务状态" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if process.terminationStatus == 0 {
            return text.contains("state = running") ? "监控运行中 · 每 3 秒检查" : "服务已加载，等待启动 / 恢复"
        }
        return installed ? "已安装，服务未加载" : "尚未启用"
    }

    static func install(rules: String) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let list = staging.appendingPathComponent("proxies.list")
        let jobFile = staging.appendingPathComponent("watchdog.plist")
        guard !rules.utf8.contains(0), rules.utf8.count <= 1024 * 1024 else {
            throw Privileged.Failure.failed("名单过大或含有无效字符")
        }
        try rules.write(to: list, atomically: true, encoding: .utf8)
        // Use the daemon's parser so UI and enforcement cannot disagree about a rule.
        let validator = Process()
        validator.executableURL = bundledBinary
        validator.arguments = ["--check", list.path]
        let output = Pipe()
        validator.standardError = output
        validator.standardOutput = FileHandle.nullDevice
        try validator.run()
        let detail = output.fileHandleForReading.readDataToEndOfFile()
        validator.waitUntilExit()
        guard validator.terminationStatus == 0 else {
            throw Privileged.Failure.failed(String(decoding: detail, as: UTF8.self))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: job(), format: .xml, options: 0)
        try data.write(to: jobFile)
        let q = Privileged.quoted
        // Root-owned private directory: user-writable rules/binaries must not remain active.
        // Stage all files before stopping a running service; rename each file atomically.
        let command = "set -e; "
            + "test ! -L \(q(directory)); "
            + "/usr/bin/install -d -o root -g wheel -m 755 \(q(directory)); "
            + "/bin/rm -f \(q(binary + ".new")) \(q(rulesPath + ".new")) \(q(plist + ".new")); "
            + "/usr/bin/install -o root -g wheel -m 755 \(q(bundledBinary.path)) \(q(binary + ".new")); "
            + "/usr/bin/install -o root -g wheel -m 644 \(q(list.path)) \(q(rulesPath + ".new")); "
            + "/usr/bin/install -o root -g wheel -m 644 \(q(jobFile.path)) \(q(plist + ".new")); "
            + "if /bin/launchctl print system/\(label) >/dev/null 2>&1; then /bin/launchctl bootout system/\(label); fi; "
            + "/bin/mv -f \(q(binary + ".new")) \(q(binary)); "
            + "/bin/mv -f \(q(rulesPath + ".new")) \(q(rulesPath)); "
            + "/bin/mv -f \(q(plist + ".new")) \(q(plist)); "
            + "/bin/launchctl enable system/\(label); "
            + "/bin/launchctl bootstrap system \(q(plist))"
        try Privileged.run(command)
    }

    static func uninstall() throws {
        let q = Privileged.quoted
        try Privileged.run("set -e; if /bin/launchctl print system/\(label) >/dev/null 2>&1; then "
            + "/bin/launchctl bootout system/\(label); fi; "
            + "/bin/rm -f \(q(plist)) \(q(binary)) \(q(rulesPath))")
    }
}
