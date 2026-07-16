import Foundation

/// 应用数据目录：~/Library/Application Support/mm/
/// 与旧版 Node 项目的 data/ 目录结构一致，便于迁移
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("mm", isDirectory: true)
    }()

    static var dataDir: URL { root.appendingPathComponent("data", isDirectory: true) }
    static var configsDir: URL { dataDir.appendingPathComponent("configs", isDirectory: true) }
    static var ruleProvidersDir: URL { dataDir.appendingPathComponent("rule-providers", isDirectory: true) }
    static var dataFile: URL { dataDir.appendingPathComponent("data.json") }
    static var rulesFile: URL { dataDir.appendingPathComponent("rules.txt") }
    static var outputConfig: URL { dataDir.appendingPathComponent("config.yaml") }

    static func ensure() {
        for dir in [root, dataDir, configsDir, ruleProvidersDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 内核路径自动探测：优先旧项目里已提权的二进制
    static func detectKernel() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            root.appendingPathComponent("bin/mihomo").path,
            home.appendingPathComponent("mm/mmac/mihomo").path,
            home.appendingPathComponent("mm/mihomo").path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
