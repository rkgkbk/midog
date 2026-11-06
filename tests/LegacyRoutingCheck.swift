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
        var section = ""
        var providers: [String: [String: Any]] = [:]
        var groups: [String: [String: Any]] = [:]
        for line in output.yaml.components(separatedBy: "\n") {
            if !line.hasPrefix(" ") { section = line; continue }
            if section == "proxy-providers:", let colon = line.range(of: ": ") {
                let name = try JSONDecoder().decode(String.self, from: Data(line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces).utf8))
                providers[name] = try JSONSerialization.jsonObject(with: Data(line[colon.upperBound...].utf8)) as? [String: Any]
            }
            if section == "proxy-groups:", line.hasPrefix("  - ") {
                let group = try JSONSerialization.jsonObject(with: Data(line.dropFirst(4).utf8)) as! [String: Any]
                groups[group["name"] as! String] = group
            }
        }
        let manual = groups["PROXY"]!["use"] as! [String]
        let auto = groups["AUTO"]!["use"] as! [String]
        assert(Set(manual).isDisjoint(with: auto))
        assert(manual.count == 1 && auto.count == 1)
        for name in manual + auto {
            let health = providers[name]!["health-check"] as! [String: Any]
            assert(health["enable"] as? Bool == false)
        }
        assert(providers[manual[0]]!["path"] as? String == providers[auto[0]]!["path"] as? String)
        assert(groups["AUTO"]!["lazy"] as? Bool == true)
        assert(groups["AUTO"]!["interval"] as? Int == 300)
        print("Routing: manual and AUTO health checks are isolated")
    }
}
