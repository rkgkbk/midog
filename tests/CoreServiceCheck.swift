import Foundation

@main
enum CoreServiceCheck {
    static func main() throws {
        let dir = URL(fileURLWithPath: "/Users/test user/Library/Application Support/midog/data")
        let data = try PropertyListSerialization.data(
            fromPropertyList: CoreService.job(dataDir: dir), format: .xml, options: 0)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        assert(plist["ProgramArguments"] as? [String] == [CoreService.binary, "-d", dir.path])
        assert(plist["WorkingDirectory"] as? String == dir.path)
        assert(plist["KeepAlive"] as? Bool == true)
        assert(plist["RunAtLoad"] as? Bool == true)
    }
}
