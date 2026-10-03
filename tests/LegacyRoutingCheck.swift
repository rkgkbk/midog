import Foundation

@main
enum LegacyRoutingCheck {
    static func main() throws {
        let old = """
        {"sources":[{"name":"sample.yaml","enabled":true}],
         "egressSplit":{"proxyInterface":"en5","proxyLabel":"USB","directInterface":"en0","directLabel":"Wi-Fi","enabledAt":"2026-01-01"}}
        """
        let appData = try JSONDecoder().decode(AppData.self, from: Data(old.utf8))
        let encoded = try JSONEncoder().encode(appData)
        assert(!String(decoding: encoded, as: UTF8.self).contains("egressSplit"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configs = root.appendingPathComponent("configs")
        try FileManager.default.createDirectory(at: configs, withIntermediateDirectories: true)
        try "proxies: []".write(to: configs.appendingPathComponent("sample.yaml"), atomically: true, encoding: .utf8)
        let output = try ConfigGenerator.generate(data: appData, rules: [], configsDir: configs,
                                                  ruleProvidersDir: root.appendingPathComponent("rule-providers")).get()
        assert(!output.yaml.contains("interface-name"))
        assert(!output.yaml.contains("DIRECT-WIFI"))
        assert(output.yaml.contains("MATCH,PROXY"))
    }
}
