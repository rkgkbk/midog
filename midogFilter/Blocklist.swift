import Foundation

struct Blocklist {
    private let exact: Set<String>
    private let suffix: Set<String>

    init(_ contents: String) {
        var exact = Set<String>()
        var suffix = Set<String>()
        for raw in contents.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("+.") {
                suffix.insert(String(line.dropFirst(2)))
            } else {
                exact.insert(line)
            }
        }
        self.exact = exact
        self.suffix = suffix
    }

    func blocks(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if exact.contains(host) || suffix.contains(host) { return true }
        var dot = host.firstIndex(of: ".")
        while let index = dot {
            let next = host.index(after: index)
            if suffix.contains(String(host[next...])) { return true }
            dot = host[next...].firstIndex(of: ".")
        }
        return false
    }
}
