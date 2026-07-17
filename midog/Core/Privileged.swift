import Foundation

/// 以 root 执行命令：弹系统自己的授权框，密码由 macOS 收集，本应用不接触。
nonisolated enum Privileged {
    enum Failure: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "已取消授权"
            case .failed(let detail):
                return detail.isEmpty ? "以管理员权限执行失败" : detail
            }
        }
    }

    /// 把值包成 shell 单引号字面量，内部的单引号按 '\'' 收尾再续
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 阻塞执行并返回标准输出，勿在主线程调用。
    /// 注意：`do shell script` 在退出码非 0 时会报错，命令若可能正常返回非 0（如 lsof 无匹配），调用方需自行补 `|| true`。
    @discardableResult
    static func run(_ shell: String) throws -> String {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 用户在授权框点「取消」时 osascript 报 -128
            if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
                throw Failure.cancelled
            }
            throw Failure.failed(message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
