import Foundation

@main
enum FocusCheck {
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected rejection") } catch {}
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let legacyFiltering = try JSONDecoder().decode(FocusState.self, from: Data("{\"domains\":[]}".utf8))
        assert(legacyFiltering.filteringEnabled && legacyFiltering.disableRequestedAt == nil)
        var filtering = FocusState()
        try filtering.apply(FocusCommand(action: .add, domain: "example.com"), at: now)
        try filtering.apply(FocusCommand(action: .start, minutes: 120), at: now)
        rejects { try filtering.apply(FocusCommand(action: .confirmDisableFiltering), at: now) }
        try filtering.apply(FocusCommand(action: .requestDisableFiltering), at: now)
        rejects { try filtering.apply(FocusCommand(action: .requestDisableFiltering), at: now.addingTimeInterval(30)) }
        rejects { try filtering.apply(FocusCommand(action: .confirmDisableFiltering), at: now.addingTimeInterval(899.999)) }
        assert(filtering.blocks("example.com", at: now.addingTimeInterval(900)))
        let pending = try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(filtering))
        assert(pending == filtering)
        var timeout = pending
        rejects { try timeout.apply(FocusCommand(action: .confirmDisableFiltering), at: now.addingTimeInterval(960)) }
        assert(timeout.filteringEnabled)
        try timeout.apply(FocusCommand(action: .requestDisableFiltering), at: now.addingTimeInterval(960))
        rejects { try timeout.apply(FocusCommand(action: .confirmDisableFiltering), at: now.addingTimeInterval(961)) }
        try filtering.apply(FocusCommand(action: .confirmDisableFiltering), at: now.addingTimeInterval(900))
        assert(!filtering.filteringEnabled && !filtering.blocks("example.com", at: now.addingTimeInterval(901)))
        assert(filtering.proxyRules == "midog-focus-empty.invalid\n")
        let disabled = try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(filtering))
        assert(!disabled.filteringEnabled)
        try filtering.apply(FocusCommand(action: .enableFiltering), at: now.addingTimeInterval(902))
        assert(filtering.blocks("example.com", at: now.addingTimeInterval(902)))
        var lastMoment = pending
        try lastMoment.apply(FocusCommand(action: .confirmDisableFiltering), at: now.addingTimeInterval(959.999))
        var resumed = disabled
        assert(resumed.filteringResumesAt == now.addingTimeInterval(4500))
        assert(!resumed.isFilteringEnabled(at: now.addingTimeInterval(4499.999)))
        assert(!resumed.restoreFilteringIfNeeded(at: now.addingTimeInterval(4499.999)))
        assert(resumed.isFilteringEnabled(at: now.addingTimeInterval(4500)))
        assert(resumed.restoreFilteringIfNeeded(at: now.addingTimeInterval(4500)))
        assert(resumed.filteringEnabled && resumed.filteringResumesAt == nil)
        assert(resumed.blocks("example.com", at: now.addingTimeInterval(4500)))
        assert(!resumed.restoreFilteringIfNeeded(at: now.addingTimeInterval(4501)))
        var legacyDisabled = try JSONDecoder().decode(FocusState.self,
            from: Data("{\"domains\":[],\"filteringEnabled\":false}".utf8))
        assert(legacyDisabled.restoreFilteringIfNeeded(at: now))
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

        // Old persisted states migrate without losing the current manual session.
        let legacy = try JSONDecoder().decode(FocusState.self, from: Data("{\"domains\":[\"example.com\"],\"endsAt\":900000000}".utf8))
        assert(legacy.schedules.isEmpty && legacy.endsAt != nil)

        let calendar = Calendar.current
        func time(_ hour: Int, _ minute: Int = 0, day: Int = 18) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        var planned = FocusState()
        try planned.apply(FocusCommand(action: .add, domain: "example.com"), at: time(1))
        let morning = FocusSchedule()
        try planned.apply(FocusCommand(action: .saveSchedule, schedule: morning), at: time(1))
        assert(!planned.isActive(at: time(5, 59)))
        assert(planned.blocks("www.example.com", at: time(6)))
        // No start event runs while asleep: reloading mid-window must still enforce the plan.
        let afterSleep = try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(planned))
        assert(!afterSleep.isActive(at: time(5, 59)))
        assert(afterSleep.blocks("example.com", at: time(8)))
        assert(afterSleep.remaining(at: time(8)) == "4:00:00")
        assert(!afterSleep.blocks("example.com", at: time(12)))
        assert(planned.remaining(at: time(6)) == "6:00:00")
        assert(planned.isActive(at: time(11, 59)))
        assert(!planned.isActive(at: time(12)))
        assert(planned.isActive(at: time(6, day: 19)))
        assert(!planned.canEditSchedules(at: time(22, 59)))
        assert(planned.canEditSchedules(at: time(23)))
        assert(planned.canEditSchedules(at: time(23, 59)))
        assert(!planned.canEditSchedules(at: time(0, day: 19)))
        var changed = morning
        changed.endMinute = 660
        for hour in [0, 5, 6, 11, 12, 22] {
            rejects { try planned.apply(FocusCommand(action: .saveSchedule, schedule: changed), at: time(hour)) }
            rejects { try planned.apply(FocusCommand(action: .deleteSchedule, scheduleID: morning.id), at: time(hour)) }
            rejects { try planned.apply(FocusCommand(action: .remove, domain: "example.com"), at: time(hour)) }
        }
        try planned.apply(FocusCommand(action: .saveSchedule, schedule: changed), at: time(23))
        assert(planned.activeEnd(at: time(6)) == time(11))
        try planned.apply(FocusCommand(action: .saveSchedule, schedule: morning), at: time(23))
        // Overlapping plans and manual extensions cannot shorten the active restriction.
        let afternoon = FocusSchedule(startMinute: 660, endMinute: 780)
        try planned.apply(FocusCommand(action: .saveSchedule, schedule: afternoon), at: time(11))
        assert(planned.activeEnd(at: time(11)) == time(13))
        try planned.apply(FocusCommand(action: .extend, minutes: 60), at: time(11))
        assert(planned.activeEnd(at: time(11)) == time(14))
        rejects { try planned.apply(FocusCommand(action: .start, minutes: 1), at: time(11)) }
        let planRestored = try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(planned))
        assert(planRestored == planned)
        assert(planRestored.blocks("example.com", at: time(6, day: 19)))
        assert(planRestored.isActive(at: time(13)))
        assert(!planRestored.isActive(at: time(14)))
        for invalid in [FocusSchedule(startMinute: -1), FocusSchedule(endMinute: 1440),
                        FocusSchedule(startMinute: 720, endMinute: 720), FocusSchedule(startMinute: 780, endMinute: 720)] {
            rejects { try planned.apply(FocusCommand(action: .saveSchedule, schedule: invalid), at: time(23)) }
        }
        try planned.apply(FocusCommand(action: .deleteSchedule, scheduleID: morning.id), at: time(23))
        assert(planned.schedules == [afternoon])
        try planned.apply(FocusCommand(action: .start, minutes: 60), at: time(23))
        rejects { try planned.apply(FocusCommand(action: .deleteSchedule, scheduleID: afternoon.id), at: time(23)) }
        rejects { try planned.apply(FocusCommand(action: .remove, domain: "example.com"), at: time(23)) }

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
        try persistence.publish(disabled, adultRules: "+.adult.test\n")
        assert((try? String(contentsOf: persistence.adultRulesFile, encoding: .utf8)) == "midog-filter-empty.invalid\n")
        try persistence.publish(resumed, adultRules: "+.adult.test\n")
        assert((try? String(contentsOf: persistence.adultRulesFile, encoding: .utf8)) == "+.adult.test\n")
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
        let unfiltered = try ConfigGenerator.generate(data: app, rules: [], configsDir: root,
            ruleProvidersDir: root, filteringEnabled: false).get().yaml
        for provider in MANDATORY_RULE_PROVIDERS {
            assert(!unfiltered.contains("RULE-SET," + provider.provider.name + ",REJECT"))
        }
        let dynamic = try ConfigGenerator.generate(data: app, rules: [], configsDir: root,
            ruleProvidersDir: root, filteringEnabled: false, adultRulesFile: persistence.adultRulesFile).get().yaml
        assert(dynamic.contains(persistence.adultRulesFile.path))
        assert(dynamic.contains("RULE-SET,__MIDOG_ADULT_BLOCK,REJECT"))
        print("Focus checks passed: validation, locked mutations, extension, persistence, expiry, daily schedules, editing window, migration, rule priority")
    }
}
