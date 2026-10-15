import Foundation

/// 独立于 UI 和代理内核的 launchd 系统服务。
nonisolated enum WatchdogService {
    static let label = "com.xx.midog.watchdog"
    static let directory = "/Library/Application Support/midog-watchdog"
    static let binary = directory + "/midog-watchdog"
    private static let legacyRulesPath = directory + "/proxies.list"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static var installed: Bool { FileManager.default.fileExists(atPath: plist) }

    static var bundledBinary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/midog-watchdog")
    }

    /// Read the catalogue from the bundled executable; no external rules can override it.
    static func catalog() throws -> String {
        let process = Process()
        process.executableURL = bundledBinary
        process.arguments = ["--list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Privileged.Failure.failed("无法读取内置代理目录")
        }
        return String(decoding: bytes, as: UTF8.self)
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

    static func install() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let jobFile = staging.appendingPathComponent("watchdog.plist")
        // Ensure the embedded helper is executable before requesting authorization.
        _ = try catalog()
        let data = try PropertyListSerialization.data(fromPropertyList: job(), format: .xml, options: 0)
        try data.write(to: jobFile)
        let q = Privileged.quoted
        // The catalogue is compiled into the executable installed in this root-owned directory.
        // Stage all files before stopping a running service; rename each file atomically.
        let command = "set -e; "
            + "test ! -L \(q(directory)); "
            + "/usr/bin/install -d -o root -g wheel -m 755 \(q(directory)); "
            + "/bin/rm -f \(q(binary + ".new")) \(q(plist + ".new")); "
            + "/usr/bin/install -o root -g wheel -m 755 \(q(bundledBinary.path)) \(q(binary + ".new")); "
            + "/usr/bin/install -o root -g wheel -m 644 \(q(jobFile.path)) \(q(plist + ".new")); "
            + "if /bin/launchctl print system/\(label) >/dev/null 2>&1; then /bin/launchctl bootout system/\(label); fi; "
            + "/bin/mv -f \(q(binary + ".new")) \(q(binary)); "
            + "/bin/mv -f \(q(plist + ".new")) \(q(plist)); "
            + "/bin/launchctl enable system/\(label); "
            + "/bin/launchctl bootstrap system \(q(plist)); "
            + "/bin/rm -f \(q(legacyRulesPath))"
        try Privileged.run(command)
    }

}
