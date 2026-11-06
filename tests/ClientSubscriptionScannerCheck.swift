import Foundation
import SQLite3

@main enum ClientSubscriptionScannerCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ folder: String, _ sql: String) throws -> URL {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("database.sqlite")
            var db: OpaquePointer?
            precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            return url
        }
        let a = try fixture("arbitrary-wrapper", """
            CREATE TABLE profiles(id INTEGER, url TEXT, label TEXT);
            INSERT INTO profiles VALUES(1,'https://expired.invalid/token','已过期');
            INSERT INTO profiles VALUES(2,'','离线');
            INSERT INTO profiles VALUES(3,'https://example.com','缺少缓存');
            INSERT INTO profiles VALUES(4,'','符号链接');
            """)
        let profiles = a.deletingLastPathComponent().appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        for id in [1, 2] {
            try "proxies: []".write(to: profiles.appendingPathComponent("\(id).yaml"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("4.yaml"),
            withDestinationURL: profiles.appendingPathComponent("1.yaml"))
        _ = try fixture("unrelated", "CREATE TABLE profiles(label TEXT,url TEXT);")
        _ = try fixture("too/deep/for/scan", "CREATE TABLE profiles(id INTEGER,label TEXT);")
        let before = try Data(contentsOf: a)
        let scan = ClientSubscriptionScanner.scan(root: root)
        precondition(scan.candidates.count == 2)
        precondition(scan.unreadable == 0 && !scan.truncated)
        precondition(Set(scan.candidates.map { $0.file.lastPathComponent }) == ["1.yaml", "2.yaml"])
        precondition(Set(scan.candidates.map(\.id)).count == 2)
        let rows = try ClientSubscriptionScanner.read(database: a)
        precondition(rows.count == 2)
        let after = try Data(contentsOf: a)
        precondition(after == before)
        print("ClientSubscriptionScanner: local cache, expired/empty URL, missing file, symlink and read-only checks passed")
    }
}
