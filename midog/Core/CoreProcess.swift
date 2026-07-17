import Foundation

struct LogEntry: Identifiable, Equatable {
    enum Level: String {
        case info, error, system
    }

    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}

/// mihomo 子进程管理：启动、停止（SIGTERM → 超时 SIGKILL）、日志采集
@MainActor
final class CoreProcess {
    private var process: Process?

    var onLog: ((LogEntry.Level, String) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }
    var pid: Int32? { isRunning ? process?.processIdentifier : nil }

    enum StartError: LocalizedError {
        case alreadyRunning
        case binaryMissing(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "内核已在运行中"
            case .binaryMissing(let p): return "内核不存在或不可执行: \(p)"
            case .launchFailed(let m): return "启动失败: \(m)"
            }
        }
    }

    func start(binaryPath: String, dataDir: URL) throws -> Int32 {
        guard !isRunning else { throw StartError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw StartError.binaryMissing(binaryPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = ["-d", dataDir.path]
        p.currentDirectoryURL = dataDir

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.emit(text, level: .info) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.emit(text, level: .error) }
        }

        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.process === proc { self.process = nil }
                self.onLog?(.system, "进程退出, code: \(code)")
                self.onExit?(code)
            }
        }

        do {
            try p.run()
        } catch {
            throw StartError.launchFailed(error.localizedDescription)
        }
        process = p
        return p.processIdentifier
    }

    /// 优雅停止：SIGTERM 后最多等 5 秒，仍未退出则 SIGKILL
    func stop() async {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        for _ in 0..<50 {
            if !p.isRunning { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }

    /// 应用退出时的同步兜底
    func terminateNow() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        // 给内核一点时间清理 TUN 网卡/路由
        for _ in 0..<10 {
            if !p.isRunning { break }
            usleep(100_000)
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    private func emit(_ text: String, level: LogEntry.Level) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                onLog?(level, trimmed)
            }
        }
    }
}
