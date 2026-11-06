import Foundation

/// Shared by the app and the system extension. The extension is the only writer.
nonisolated struct FocusState: Codable, Equatable, Sendable {
    static let disableWait: TimeInterval = 15 * 60
    static let confirmationWindow: TimeInterval = 60
    static let disableDuration: TimeInterval = 60 * 60
    var filteringResumesAt: Date?
    var filteringEnabled = true
    var disableRequestedAt: Date?
    var domains: [String] = []
    var startedAt: Date?
    var endsAt: Date?

    var schedules: [FocusSchedule] = []

    private enum CodingKeys: String, CodingKey { case domains, startedAt, endsAt, schedules, filteringEnabled, disableRequestedAt, filteringResumesAt }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filteringResumesAt = try values.decodeIfPresent(Date.self, forKey: .filteringResumesAt)
        filteringEnabled = try values.decodeIfPresent(Bool.self, forKey: .filteringEnabled) ?? true
        disableRequestedAt = try values.decodeIfPresent(Date.self, forKey: .disableRequestedAt)
        domains = try values.decode([String].self, forKey: .domains)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        endsAt = try values.decodeIfPresent(Date.self, forKey: .endsAt)
        schedules = try values.decodeIfPresent([FocusSchedule].self, forKey: .schedules) ?? []
        for schedule in schedules { try schedule.validate() }
    }

    func activeEnd(at now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let scheduled = schedules.compactMap { $0.activeEnd(at: now, calendar: calendar) }.max()
        return [endsAt, scheduled].compactMap { $0 }.filter { $0 > now }.max()
    }

    func isActive(at now: Date = Date()) -> Bool { activeEnd(at: now) != nil }
    func blocks(_ host: String, at now: Date = Date()) -> Bool {
        guard isFilteringEnabled(at: now), isActive(at: now) else { return false }
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { name == $0 || name.hasSuffix("." + $0) }
    }
    func remaining(at now: Date = Date()) -> String {
        let seconds = max(0, Int(ceil(activeEnd(at: now)?.timeIntervalSince(now) ?? 0)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func canEditSchedules(at now: Date = Date()) -> Bool {
        Calendar.current.component(.hour, from: now) == 23 && !isActive(at: now)
    }

    func canRemoveDomains(at now: Date = Date()) -> Bool {
        !isActive(at: now) && (schedules.isEmpty || canEditSchedules(at: now))
    }

    mutating func apply(_ command: FocusCommand, at now: Date = Date()) throws {
        restoreFilteringIfNeeded(at: now)
        switch command.action {
        case .status, .configureProxy: break
        case .requestDisableFiltering:
            guard filteringEnabled else { throw FocusFailure("过滤已经关闭") }
            if let requested = disableRequestedAt, now < requested.addingTimeInterval(Self.disableWait + Self.confirmationWindow) {
                throw FocusFailure("关闭请求正在等待或确认中")
            }
            disableRequestedAt = now
        case .confirmDisableFiltering:
            guard filteringEnabled, let requested = disableRequestedAt,
                  now >= requested.addingTimeInterval(Self.disableWait), now < requested.addingTimeInterval(Self.disableWait + Self.confirmationWindow) else {
                throw FocusFailure("请先等待 15 分钟，并在之后的 1 分钟内确认关闭；超时请重新申请")
            }
            filteringResumesAt = now.addingTimeInterval(Self.disableDuration)
            filteringEnabled = false
            disableRequestedAt = nil
        case .enableFiltering:
            filteringEnabled = true
            filteringResumesAt = nil
            disableRequestedAt = nil
        case .add:
            let domain = try Self.normalize(command.domain ?? "")
            guard domains.contains(domain) || domains.count < 2000 else { throw FocusFailure("最多添加 2000 个网站") }
            if !domains.contains(domain) { domains.append(domain); domains.sort() }
        case .remove:
            guard canRemoveDomains(at: now) else { throw FocusFailure("专注期间不能删除网站；有计划时仅每天 23:00–24:00 可删除") }
            let domain = try Self.normalize(command.domain ?? "")
            domains.removeAll { $0 == domain }
        case .saveSchedule:
            guard let schedule = command.schedule else { throw FocusFailure("缺少专注计划") }
            try schedule.validate()
            guard !domains.isEmpty else { throw FocusFailure("请先添加至少一个网站") }
            if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
                guard canEditSchedules(at: now) else { throw FocusFailure("计划仅每天 23:00–24:00 且未在专注时可修改") }
                schedules[index] = schedule
            } else {
                guard schedules.count < 50 else { throw FocusFailure("最多添加 50 个专注计划") }
                schedules.append(schedule)
            }
            schedules.sort { $0.startMinute < $1.startMinute }
        case .deleteSchedule:
            guard canEditSchedules(at: now) else { throw FocusFailure("计划仅每天 23:00–24:00 且未在专注时可删除") }
            guard let id = command.scheduleID, schedules.contains(where: { $0.id == id }) else {
                throw FocusFailure("专注计划不存在")
            }
            schedules.removeAll { $0.id == id }
        case .start, .extend:
            guard let minutes = command.minutes, (1...1440).contains(minutes) else {
                throw FocusFailure("请输入 1–1440 分钟")
            }
            if command.action == .start {
                guard !isActive(at: now) else { throw FocusFailure("专注已经开始，只能延长时间") }
                guard !domains.isEmpty else { throw FocusFailure("请先添加至少一个网站") }
                startedAt = now
                endsAt = now.addingTimeInterval(Double(minutes * 60))
            } else {
                guard let end = activeEnd(at: now) else { throw FocusFailure("本次专注已经结束") }
                guard end.timeIntervalSince(now) + Double(minutes * 60) <= 86400 else {
                    throw FocusFailure("剩余专注时间最多 24 小时")
                }
                endsAt = end.addingTimeInterval(Double(minutes * 60))
            }
        }
    }

    func isFilteringEnabled(at now: Date = Date()) -> Bool {
        filteringEnabled || filteringResumesAt.map { now >= $0 } != false
    }

    @discardableResult
    mutating func restoreFilteringIfNeeded(at now: Date = Date()) -> Bool {
        guard !filteringEnabled, isFilteringEnabled(at: now) else { return false }
        filteringEnabled = true
        filteringResumesAt = nil
        disableRequestedAt = nil
        return true
    }

    static func normalize(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("*"),
              let url = URL(string: value.contains("://") ? value : "https://" + value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let raw = url.host else {
            throw FocusFailure("请输入有效的网站域名或 http/https 链接")
        }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                  && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), !labels.allSatisfy({ Int($0) != nil }) else {
            throw FocusFailure("请输入完整域名，例如 example.com；不支持 IP 地址")
        }
        return host
    }

    var proxyRules: String {
        let active = isFilteringEnabled() && isActive() ? domains : []
        // An empty domain provider is rejected by some mihomo versions.
        return (active.isEmpty ? ["midog-focus-empty.invalid"] : active.map { "+." + $0 }).joined(separator: "\n") + "\n"
    }
}

/// Daily wall-clock times in the Mac's current time zone.
nonisolated struct FocusSchedule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var startMinute: Int = 360
    var endMinute: Int = 720

    func validate() throws {
        guard (0..<1440).contains(startMinute), (1..<1440).contains(endMinute),
              startMinute < endMinute else {
            throw FocusFailure("请选择同一天内的开始和结束时间，结束时间须晚于开始时间")
        }
    }

    func activeEnd(at now: Date, calendar: Calendar = .current) -> Date? {
        guard let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60,
                                        second: 0, of: now),
              let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60,
                                      second: 0, of: now), start <= now, now < end else { return nil }
        return end
    }

    var timeRange: String {
        String(format: "%02d:%02d–%02d:%02d", startMinute / 60, startMinute % 60, endMinute / 60, endMinute % 60)
    }
}

nonisolated struct FocusCommand: Codable, Sendable {
    enum Action: String, Codable { case status, add, remove, start, extend, configureProxy, saveSchedule, deleteSchedule, requestDisableFiltering, confirmDisableFiltering, enableFiltering }
    var action: Action
    var domain: String?
    var minutes: Int?
    var controller: String?
    var secret: String?
    var schedule: FocusSchedule?
    var scheduleID: UUID?
}

nonisolated struct FocusReply: Codable, Sendable {
    var state: FocusState
    var error: String?
    var proxyStatus: String?
}

nonisolated struct FocusFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Kept separate from XPC so persistence and recovery can be exercised without installing a filter.
nonisolated struct FocusPersistence {
    let directory: URL
    private var stateFile: URL { directory.appendingPathComponent("state.json") }
    var rulesFile: URL { directory.appendingPathComponent("domains.list") }

    func load() throws -> FocusState {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return FocusState() }
        return try JSONDecoder().decode(FocusState.self, from: Data(contentsOf: stateFile))
    }

    func save(_ state: FocusState) throws {
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    var adultRulesFile: URL { directory.appendingPathComponent("adult.list") }

    func publish(_ state: FocusState, adultRules: String? = nil) throws {
        try publish(state.proxyRules, to: rulesFile)
        if let adultRules {
            try publish(state.isFilteringEnabled() ? adultRules : "midog-filter-empty.invalid\n", to: adultRulesFile)
        }
    }

    private func publish(_ contents: String, to file: URL) throws {
        let bytes = Data(contents.utf8)
        if (try? Data(contentsOf: file)) != bytes {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
    }
}
