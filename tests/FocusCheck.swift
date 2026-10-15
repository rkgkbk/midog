import Foundation

@main
enum FocusCheck {
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected rejection") } catch {}
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var state = FocusState()
        rejects { try state.apply(FocusCommand(action: .start, minutes: 25), at: now) }
        try state.apply(FocusCommand(action: .add, domain: " HTTPS://Example.COM/path?q=1 "), at: now)
        try state.apply(FocusCommand(action: .add, domain: "example.com."), at: now)
        assert(state.domains == ["example.com"])
        for invalid in ["", "*.example.com", "ftp://example.com", "https://user:pass@example.com", "https://", "127.0.0.1", "example..com", "-x.com", "x-.com", "bad name.com", "example.com\nRULE-SET,foo,DIRECT"] {
            rejects { _ = try FocusState.normalize(invalid) }
        }
        for invalid in [0, -1, 1441, Int.max] {
            rejects { try state.apply(FocusCommand(action: .start, minutes: invalid), at: now) }
        }
        assert(!state.blocks("www.example.com", at: now))
        try state.apply(FocusCommand(action: .start, minutes: 25), at: now)
        assert(state.endsAt == now.addingTimeInterval(1500))
        assert(state.remaining(at: now) == "25:00")
        assert(state.blocks("WWW.Example.Com.", at: now))
        assert(!state.blocks("notexample.com", at: now))
        assert(!state.blocks("example.com.evil.test", at: now))
        rejects { try state.apply(FocusCommand(action: .remove, domain: "example.com"), at: now) }
        rejects { try state.apply(FocusCommand(action: .start, minutes: 1), at: now) }
        try state.apply(FocusCommand(action: .add, domain: "other.test"), at: now)
        assert(state.blocks("other.test", at: now))
        try state.apply(FocusCommand(action: .extend, minutes: 45), at: now)
        assert(state.remaining(at: now) == "1:10:00")
        rejects { try state.apply(FocusCommand(action: .extend, minutes: 1440), at: now) }

        // Restart uses the persisted absolute deadline, rather than a new countdown.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        var restored = try JSONDecoder().decode(FocusState.self, from: Data(contentsOf: file))
        assert(restored == state)
        assert(restored.blocks("example.com", at: now.addingTimeInterval(4199)))
        assert(!restored.blocks("example.com", at: now.addingTimeInterval(4200)))
        assert(restored.remaining(at: now.addingTimeInterval(5000)) == "00:00")
        rejects { try restored.apply(FocusCommand(action: .extend, minutes: 1), at: now.addingTimeInterval(4200)) }
        try restored.apply(FocusCommand(action: .remove, domain: "example.com"), at: now.addingTimeInterval(4200))
        assert(restored.domains == ["other.test"])
        try restored.apply(FocusCommand(action: .start, minutes: 1), at: now.addingTimeInterval(5000))
        assert(restored.endsAt == now.addingTimeInterval(5060))

        // User DIRECT rules and a colliding custom provider cannot override focus rules.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "proxies: []".write(to: root.appendingPathComponent("sample.yaml"), atomically: true, encoding: .utf8)
        let persistence = FocusPersistence(directory: root)
        let initial = try persistence.load()
        assert(initial == FocusState())
        var live = FocusState()
        try live.apply(FocusCommand(action: .add, domain: "example.com"))
        try live.apply(FocusCommand(action: .start, minutes: 1))
        try persistence.save(live)
        try persistence.publish(live)
        let saved = try persistence.load()
        assert(saved == live)
        let activeRules = try String(contentsOf: persistence.rulesFile, encoding: .utf8)
        assert(activeRules == "+.example.com\n")
        var expired = live
        expired.endsAt = Date.distantPast
        try persistence.publish(expired)
        let expiredRules = try String(contentsOf: persistence.rulesFile, encoding: .utf8)
        assert(expiredRules == "midog-focus-empty.invalid\n")
        let stateFile = root.appendingPathComponent("state.json")
        try Data("broken".utf8).write(to: stateFile)
        rejects { _ = try persistence.load() }
        let damaged = try String(contentsOf: stateFile, encoding: .utf8)
        assert(damaged == "broken")
        let app = try JSONDecoder().decode(AppData.self, from: Data("""
        {"sources":[{"name":"sample.yaml","enabled":true}],
         "ruleProviders":[{"name":"__MIDOG_FOCUS","url":"https://example.com/fake","target":"DIRECT"}]}
        """.utf8))
        let output = try ConfigGenerator.generate(data: app, rules: ["DOMAIN-SUFFIX,other.test,DIRECT"],
                                                  configsDir: root, ruleProvidersDir: root,
                                                  focusRulesFile: root.appendingPathComponent("focus.list")).get().yaml
        assert(output.contains("RULE-SET,__MIDOG_FOCUS,REJECT"))
        assert(!output.contains("https://example.com/fake"))
        assert(output.range(of: "RULE-SET,__MIDOG_FOCUS,REJECT")!.lowerBound < output.range(of: "DOMAIN-SUFFIX,other.test,DIRECT")!.lowerBound)
        print("Focus checks passed: validation, locked mutations, extension, persistence, expiry, rule priority")
    }
}
