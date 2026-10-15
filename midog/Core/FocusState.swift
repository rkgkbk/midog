import Foundation

/// Shared by the app and the system extension. The extension is the only writer.
nonisolated struct FocusState: Codable, Equatable, Sendable {
    var domains: [String] = []
    var startedAt: Date?
    var endsAt: Date?

    func isActive(at now: Date = Date()) -> Bool { endsAt.map { $0 > now } ?? false }
    func blocks(_ host: String, at now: Date = Date()) -> Bool {
        guard isActive(at: now) else { return false }
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { name == $0 || name.hasSuffix("." + $0) }
    }
    func remaining(at now: Date = Date()) -> String {
        let seconds = max(0, Int(ceil(endsAt?.timeIntervalSince(now) ?? 0)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    mutating func apply(_ command: FocusCommand, at now: Date = Date()) throws {
        switch command.action {
        case .status, .configureProxy: break
        case .add:
            let domain = try Self.normalize(command.domain ?? "")
            guard domains.contains(domain) || domains.count < 2000 else { throw FocusFailure("最多添加 2000 个网站") }
            if !domains.contains(domain) { domains.append(domain); domains.sort() }
        case .remove:
            guard !isActive(at: now) else { throw FocusFailure("专注期间只能添加网站，不能删除或修改") }
            let domain = try Self.normalize(command.domain ?? "")
            domains.removeAll { $0 == domain }
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
                guard isActive(at: now), let end = endsAt else { throw FocusFailure("本次专注已经结束") }
                guard end.timeIntervalSince(now) + Double(minutes * 60) <= 86400 else {
                    throw FocusFailure("剩余专注时间最多 24 小时")
                }
                endsAt = end.addingTimeInterval(Double(minutes * 60))
            }
        }
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
        let active = isActive() ? domains : []
        // An empty domain provider is rejected by some mihomo versions.
        return (active.isEmpty ? ["midog-focus-empty.invalid"] : active.map { "+." + $0 }).joined(separator: "\n") + "\n"
    }
}

nonisolated struct FocusCommand: Codable, Sendable {
    enum Action: String, Codable { case status, add, remove, start, extend, configureProxy }
    var action: Action
    var domain: String?
    var minutes: Int?
    var controller: String?
    var secret: String?
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

    func publish(_ state: FocusState) throws {
        let bytes = Data(state.proxyRules.utf8)
        if (try? Data(contentsOf: rulesFile)) != bytes {
            try bytes.write(to: rulesFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rulesFile.path)
        }
    }
}
