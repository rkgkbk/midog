import Foundation

/// launchd 是 mihomo 的唯一进程管理者；退出 midog 不影响内核。
nonisolated enum CoreService {
    static let label = "com.xx.midog.mihomo"
    static let binary = "/Library/PrivilegedHelperTools/\(label)"
    static let plist = "/Library/LaunchDaemons/\(label).plist"

    static var installed: Bool { FileManager.default.fileExists(atPath: plist) }

    static func pid() -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "system/\(label)"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "pid" {
                return Int32(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func job(dataDir: URL) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [binary, "-d", dataDir.path],
            "WorkingDirectory": dataDir.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 2,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]
    }

    static func waitForPID() async -> Int32? {
        for _ in 0..<50 {
            if let pid = pid() { return pid }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 参数与原来的子进程启动完全相同：mihomo -d <dataDir>，工作目录也相同。
    static func installAndStart(source: String, dataDir: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: job(dataDir: dataDir), format: .xml, options: 0)
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        try data.write(to: staged, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staged) }

        // 内核和 job 均安装到 root 管理的目录；不能让 launchd 以 root 执行用户可替换的二进制。
        let command = "if /bin/launchctl print system/\(label) >/dev/null 2>&1; then /bin/launchctl bootout system/\(label) || exit; fi; "
            + "/usr/bin/install -o root -g wheel -m 755 \(Privileged.quoted(source)) \(Privileged.quoted(binary)) && "
            + "/usr/bin/install -o root -g wheel -m 644 \(Privileged.quoted(staged.path)) \(Privileged.quoted(plist)) && "
            + "/bin/launchctl bootstrap system \(Privileged.quoted(plist))"
        try Privileged.run(command)
    }

    static func stop() throws {
        let command = "if /bin/launchctl print system/\(label) >/dev/null 2>&1; then "
            + "/bin/launchctl bootout system/\(label) || exit; fi; "
            + "/bin/rm -f \(Privileged.quoted(plist))"
        try Privileged.run(command)
    }
}
