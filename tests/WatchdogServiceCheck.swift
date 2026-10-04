import Foundation

@main
enum WatchdogServiceCheck {
    static func main() throws {
        let serialized = try PropertyListSerialization.data(fromPropertyList: WatchdogService.job(), format: .xml, options: 0)
        let job = try PropertyListSerialization.propertyList(from: serialized, format: nil) as! [String: Any]
        assert(job["ProgramArguments"] as? [String] == [WatchdogService.binary])
        assert(job["RunAtLoad"] as? Bool == true)
        assert(job["KeepAlive"] as? Bool == true)
        assert(job["UserName"] as? String == "root")
        assert(job["ProcessType"] as? String == "Background")
        assert(WatchdogService.label != CoreService.label)
        assert(WatchdogService.binary != CoreService.binary)
        print("Watchdog launchd configuration passed")
    }
}
