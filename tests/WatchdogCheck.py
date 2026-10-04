"""No root or installation: signals are restricted to temporary fixture executables."""
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def compile_c(source, output):
    subprocess.run(["xcrun", "clang", "-std=c17", "-Os", "-Wall", "-Wextra", "-Werror",
                    "-framework", "CoreFoundation", str(source), "-o", str(output)], check=True)


with tempfile.TemporaryDirectory(prefix="midog-watchdog-test-") as tmp:
    tmp = Path(tmp).resolve()
    binary = tmp / "watchdog"
    compile_c(ROOT / "midogWatchdog/watchdog.c", binary)
    catalog = subprocess.check_output([binary, "--list"], text=True)
    rows = [line.split("\t") for line in catalog.splitlines()]
    assert len(rows) >= 50
    assert len({(r[1], r[2]) for r in rows}) == len(rows)
    assert all(len(r) == 4 and r[3].startswith(("https://github.com/", "legacy:b7e5e48:")) for r in rows)
    for args in [["--check", "/tmp/override"], ["--dry-run", "/tmp/override"], ["--list", "/tmp/override"]]:
        assert subprocess.run([binary, *args], capture_output=True).returncode == 2

    harness = tmp / "harness.c"
    harness.write_text(r'''
#include <signal.h>
#include <libproc.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
static const char *fixture_root;
// Even when real proxy clients run on the host, this test cannot signal them.
static int fixture_kill(pid_t pid, int sig) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (!fixture_root || proc_pidpath(pid, path, sizeof(path)) <= 0 ||
        strncmp(path, fixture_root, strlen(fixture_root)) || path[strlen(fixture_root)] != '/') {
        errno = ESRCH; return -1;
    }
    return kill(pid, sig);
}
#define kill fixture_kill
#define main watchdog_main
#include "''' + str(ROOT / 'midogWatchdog/watchdog.c') + r'''"
#undef main
#undef kill
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--probe")) {
        char line[PROC_PIDPATHINFO_MAXSIZE];
        while (fgets(line, sizeof(line), stdin)) {
            line[strcspn(line, "\n")] = 0;
            printf("%d\n", matches(line)); fflush(stdout);
        }
        clear_cache(); return 0;
    }
    if (argc != 2) return 2;
    fixture_root = argv[1];
    return monitor(false);
}
'''.replace('\\"', '"'))
    runner = tmp / "runner"
    compile_c(harness, runner)
    probe = subprocess.Popen([runner, "--probe"], text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def match(path, expected):
        probe.stdin.write(str(path) + "\n")
        probe.stdin.flush()
        actual = probe.stdout.readline().strip()
        assert actual == str(int(expected)), (path, expected, actual)

    def app(name, identifier, executable="renamed-core", fmt=plistlib.FMT_XML):
        contents = tmp / name / "Contents"
        (contents / "MacOS").mkdir(parents=True, exist_ok=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}, fmt=fmt))
        return contents / "MacOS" / executable

    try:
        for project, kind, value, source in rows:
            if kind == "executable":
                match(tmp / "Downloads" / value, True)
                match(tmp / (value + "-backup"), False)
            else:
                match(app("Renamed.app", value, fmt=plistlib.FMT_BINARY), True)
        for path in ["/opt/homebrew/bin/mihomo", "/usr/local/Cellar/mihomo/1.0/bin/mihomo",
                     "/Volumes/External Disk/sing-box", "/private/tmp/random/xray"]:
            match(path, True)
        for path in ["/System/bin/mihomo", "/usr/bin/xray", "/tmp/midog", "/tmp/midog-core",
                     "/tmp/midog-watchdog", "/tmp/clash-report", "/tmp/core", "/tmp/python", "/tmp/ssh"]:
            match(path, False)
        match(app("Own.app", "com.xx.midog", "mihomo"), False)
        match(app("Own.systemextension", "com.xx.midog.filter", "mihomo"), False)
        match(app("Renamed.systemextension", "io.nekohasekai.sfamt.system"), True)
        match(app("Nested.app", "app.hiddify.com", "Helper.app/Contents/MacOS/unknown"), True)
        path = app("Changed.app", "org.example.unknown")
        match(path, False)
        app("Changed.app", "app.hiddify.com")
        match(path, True)  # invalidates a negative cache entry
        app("Changed.app", "org.example.unknown")
        match(path, False)  # invalidates a positive cache entry
        (path.parent.parent / "Info.plist").write_bytes(b"not a plist")
        match(path, False)
        (path.parent.parent / "Info.plist").write_bytes(plistlib.dumps(["app.hiddify.com"]))
        match(path, False)
        # Exercise bounded cache eviction without changing matches.
        for i in range(270):
            match(app(f"Cache{i}.app", "org.example.unknown"), False)
        match(app("Renamed.app", "app.hiddify.com"), True)
    finally:
        probe.stdin.close()
        assert probe.wait(timeout=5) == 0
        probe.stdout.close()

    fixture = tmp / "fixture.c"
    fixture.write_text('#include <signal.h>\n#include <unistd.h>\n#include <stdio.h>\n'
                       'int main(int argc, char **argv) { (void)argv;\n'
                       'if (argc > 1) signal(SIGTERM, SIG_IGN);\n'
                       'puts("ready"); fflush(stdout); while (1) pause(); }\n')
    target = tmp / "mihomo"
    neighbor = tmp / "mihomo-backup"
    compile_c(fixture, target)
    shutil.copy2(target, neighbor)
    relocated = app("Downloads/Moved and Renamed.app", "app.hiddify.com")
    shutil.copy2(target, relocated)
    own = app("Own.app", "com.xx.midog", "mihomo")
    shutil.copy2(target, own)
    children = []
    daemon = None

    def spawn(path, stubborn=False):
        p = subprocess.Popen([path] + (["ignore-term"] if stubborn else []), stdout=subprocess.PIPE)
        children.append(p)
        assert p.stdout.readline() == b"ready\n"
        return p

    try:
        ordinary = spawn(target)
        unrelated = spawn(neighbor)
        moved = spawn(relocated)
        self_app = spawn(own)
        output = subprocess.check_output([binary, "--dry-run"], text=True)
        assert f"{ordinary.pid}\t{target}" in output
        assert f"{moved.pid}\t{relocated}" in output
        assert str(neighbor) not in output and str(own) not in output
        assert all(p.poll() is None for p in children)
        daemon = subprocess.Popen([runner, tmp])
        assert ordinary.wait(timeout=7) == -signal.SIGTERM
        assert moved.wait(timeout=7) == -signal.SIGTERM
        stubborn = spawn(target, True)
        assert stubborn.wait(timeout=10) == -signal.SIGKILL
        restarted = spawn(target)
        assert restarted.wait(timeout=7) == -signal.SIGTERM
        assert unrelated.poll() is None and self_app.poll() is None
        sample = subprocess.check_output(["/bin/ps", "-o", "rss=,%cpu=", "-p", str(daemon.pid)], text=True).strip()
        print("Test monitor RSS (KiB), CPU (%):", sample)
        daemon.terminate()
        assert daemon.wait(timeout=4) == 0
    finally:
        if daemon and daemon.poll() is None:
            daemon.kill()
            daemon.wait()
        for p in children:
            if p.poll() is None:
                p.kill()
            p.wait()
            p.stdout.close()
    print(f"Passed: {len(rows)} built-in identities, relocation, bundle rename, Homebrew, cache invalidation, "
          "self exclusion, immutable catalogue, TERM/KILL, restart and dry run")
