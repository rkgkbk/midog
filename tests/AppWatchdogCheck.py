"""Exercise the actual Swift supervisor with an inert helper, never real proxy apps."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='midog-app-watchdog-') as tmp:
    root = Path(tmp)
    pidfile = root / 'pid'
    helper = root / 'helper'
    helper.write_text('#!/bin/sh\necho $$ > "' + str(pidfile) + '"\nexec /bin/sleep 60\n')
    helper.chmod(0o700)
    source = (ROOT / 'midog/Core/WatchdogService.swift').read_text().split('/// 独立于 UI')[0]
    source += '''
nonisolated enum WatchdogService {
    static var bundledBinary: URL { URL(fileURLWithPath: BINARY) }
    static func status() -> String { "已安装，服务未加载" }
}
@main struct Check {
    @MainActor static func main() async throws {
        let monitor = AppWatchdog.shared
        func pid() throws -> Int32 {
            Int32(try String(contentsOfFile: PIDFILE, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        }
        monitor.start()
        monitor.start() // idempotent
        try await Task.sleep(for: .seconds(1))
        assert(monitor.running)
        assert(monitor.systemStatus == "已安装，服务未加载")
        let first = try pid()
        assert(kill(first, SIGKILL) == 0)
        try await Task.sleep(for: .milliseconds(300))
        assert(!monitor.running)
        try await Task.sleep(for: .seconds(4))
        let second = try pid()
        assert(first != second && monitor.running)
        monitor.stop()
        try await Task.sleep(for: .milliseconds(300))
        assert(!monitor.running)
        assert(kill(second, 0) == -1 && errno == ESRCH)
        print("Passed: disabled system service, app monitor start, crash detection, restart and shutdown")
    }
}
'''.replace('BINARY', json.dumps(str(helper))).replace('PIDFILE', json.dumps(str(pidfile)))
    swift = root / 'Check.swift'
    swift.write_text(source)
    binary = root / 'check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([binary], check=True, timeout=15)
