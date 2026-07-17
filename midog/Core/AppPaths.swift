import Foundation

/// 应用数据目录：~/Library/Application Support/midog/
nonisolated enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("midog", isDirectory: true)
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
}
