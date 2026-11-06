import Foundation
import SQLite3

/// 只读识别换皮客户端的 profiles 数据，不依赖应用标识。
enum ClientSubscriptionScanner {
    struct Candidate: Identifiable, Sendable {
        let database: URL
        let label: String
        let file: URL
        var id: String { file.path }
        var importName: String { "\(label)（\(origin)）-\(file.deletingPathExtension().lastPathComponent)" }
        var origin: String { database.deletingLastPathComponent().lastPathComponent }
    }

    struct ScanResult: Sendable {
        var candidates: [Candidate] = []
        var unreadable = 0
        var truncated = false
    }

    static func scan(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")) -> ScanResult {
        var result = ScanResult()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return result }
        var visited = 0
        var databases = 0
        var seen = Set<String>()
        for case let file as URL in files {
            visited += 1
            if visited > 20_000 { result.truncated = true; break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { files.skipDescendants(); continue }
            if values.isDirectory == true {
                if files.level >= 3 { files.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, file.lastPathComponent == "database.sqlite" else { continue }
            databases += 1
            if databases > 100 { result.truncated = true; break }
            do {
                for candidate in try read(database: file) where seen.insert(candidate.id).inserted {
                    result.candidates.append(candidate)
                }
            } catch { result.unreadable += 1 }
        }
        result.candidates.sort { ($0.origin, $0.label, $0.id) < ($1.origin, $1.label, $1.id) }
        return result
    }

    static func read(database: URL) throws -> [Candidate] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(profiles)", -1, &schema, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(schema) }
        var columns = Set<String>()
        var status = sqlite3_step(schema)
        while status == SQLITE_ROW {
            if let name = sqlite3_column_text(schema, 1) { columns.insert(String(cString: name).lowercased()) }
            status = sqlite3_step(schema)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        guard columns.isSuperset(of: ["id", "label"]) else { return [] }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT label, id FROM profiles LIMIT 200", -1, &query, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(query) }
        var found: [Candidate] = []
        status = sqlite3_step(query)
        while status == SQLITE_ROW {
            if sqlite3_column_type(query, 1) == SQLITE_INTEGER {
                let profileID = sqlite3_column_int64(query, 1)
                let file = database.deletingLastPathComponent()
                    .appendingPathComponent("profiles/\(profileID).yaml")
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true, values?.isSymbolicLink != true {
                    let label = sqlite3_column_text(query, 0).map { String(cString: $0) } ?? "订阅"
                    found.append(Candidate(database: database, label: label.isEmpty ? "订阅" : label, file: file))
                }
            }
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        return found
    }
}
