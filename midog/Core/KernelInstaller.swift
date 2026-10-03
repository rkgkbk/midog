import CryptoKit
import Foundation

/// 内置 midog-core 内核的释放。root 权限由 launchd 系统服务提供。
///
/// 内核以 gzip 压缩后打进 app 包，首次运行（以及内置版本升级后）解压到
/// AppPaths.root/bin/midog-core，随后安装到 root 管理的服务路径。
enum KernelInstaller {
    enum InstallError: LocalizedError {
        case missingBundledKernel
        case decompressionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledKernel:
                return "应用包内缺少内核文件，请重新安装 midog"
            case .decompressionFailed(let detail):
                return detail.isEmpty ? "内核解压失败" : "内核解压失败：\(detail)"
            }
        }
    }

    /// app 包内置的内核（gzip）
    nonisolated static var bundled: URL? { Bundle.main.url(forResource: "midog-core", withExtension: "gz") }

    /// 解压后的内核位置
    nonisolated static var installed: URL { AppPaths.root.appendingPathComponent("bin/midog-core", isDirectory: false) }
    nonisolated static var legacyInstalled: URL { AppPaths.root.appendingPathComponent("bin/mihomo", isDirectory: false) }

    nonisolated static func removeLegacyIfPresent() {
        try? FileManager.default.removeItem(at: legacyInstalled)
    }

    /// 记录已释放内核对应的压缩包哈希，避免每次启动都解压 43MB
    private nonisolated static var marker: URL { installed.deletingLastPathComponent().appendingPathComponent(".kernel-sha256") }

    /// 把内置内核解压到 Application Support，返回可执行文件路径。
    /// 旧版本的 setuid 副本必须替换成普通用户文件，避免可写目录中的特权程序长期存在。
    @discardableResult
    nonisolated static func installIfNeeded() throws -> URL {
        guard let bundled else { throw InstallError.missingBundledKernel }
        let fm = FileManager.default
        let target = installed
        let expected = try digest(of: bundled)

        if fm.isExecutableFile(atPath: target.path),
           !isPrivileged(target.path),
           let recorded = try? String(contentsOf: marker, encoding: .utf8),
           recorded == expected {
            return target
        }

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 先解压到临时文件再就位，避免解压中途失败留下半个内核
        let staged = target.appendingPathExtension("staged")
        try? fm.removeItem(at: staged)
        try gunzip(bundled, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // 正在运行的内核不能直接覆盖(ETXTBSY)；先 unlink —— 旧进程仍持有 inode，不受影响。
        // 旧文件可能是 root 所有的 setuid 副本，但删除只取决于所在目录的权限，故无需提权。
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staged, to: target)
        try? fm.removeItem(at: marker)
        try expected.write(to: marker, atomically: true, encoding: .utf8)
        return target
    }

    private nonisolated static func isPrivileged(_ path: String) -> Bool {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return owner == 0 && (perms & 0o4000) != 0
    }

    /// 交给 gunzip 解压：它自带 CRC 校验，且不必把 43MB 全读进内存
    private nonisolated static func gunzip(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw InstallError.decompressionFailed("无法写入 \(destination.path)")
        }
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        task.arguments = ["-c", source.path]
        task.standardOutput = sink
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            try? fm.removeItem(at: destination)
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallError.decompressionFailed(message)
        }
    }

    private nonisolated static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
