"""Run without root: only temporary fixture executables are signaled."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def compile_c(source, output):
    subprocess.run(["xcrun", "clang", "-std=c17", "-Os", "-Wall", "-Wextra", "-Werror",
                    str(source), "-o", str(output)], check=True)


with tempfile.TemporaryDirectory(prefix="midog-watchdog-test-") as tmp:
    tmp = Path(tmp).resolve()
    binary = tmp / "watchdog"
    compile_c(ROOT / "midogWatchdog/watchdog.c", binary)
    rules = tmp / "rules.list"

    def check(text, valid):
        rules.write_bytes(text if isinstance(text, bytes) else text.encode())
        result = subprocess.run([binary, "--check", rules], capture_output=True)
        assert (result.returncode == 0) == valid, (text, result.stderr)

    check("# comment\n\n/Applications/Example.app/Contents/MacOS/core\r\n", True)
    for path in ["relative", "/usr/bin/ssh", "/System/example", "/Applications/midog-core",
                 "/Applications/midog-watchdog", "/Applications/midog", "/tmp/*",
                 "/tmp/a/../b", "/tmp//a", "/tmp/a/", "/" + "a" * 5000]:
        check(path + "\n", False)
    check(b"/tmp/a\0hidden\n", False)
    check("/tmp/a\n" * 257, False)
    check("# empty is valid\n", True)
    link = tmp / "link"
    link.symlink_to(rules)
    assert subprocess.run([binary, "--check", link], capture_output=True).returncode != 0

    # A private test entry point calls the same loop with unprivileged fixture rules.
    # Production's main still requires root and its fixed root-owned configuration.
    harness = tmp / "harness.c"
    harness.write_text('#define main watchdog_main\n#include "' + str(ROOT / "midogWatchdog/watchdog.c") +
                       '"\n#undef main\nint main(int argc, char **argv) {\n'
                       'if (argc != 2 || !load_rules(argv[1], false)) return 2;\n'
                       'return monitor(false);\n}\n')
    runner = tmp / "runner"
    compile_c(harness, runner)
    fixture = tmp / "fixture.c"
    fixture.write_text('#include <signal.h>\n#include <unistd.h>\n#include <stdio.h>\n'
                       'int main(int argc, char **argv) { (void)argv;\n'
                       'if (argc > 1) signal(SIGTERM, SIG_IGN);\n'
                       'puts("ready"); fflush(stdout); while (1) pause(); }\n')
    target = tmp / "proxy-core"
    neighbor = tmp / "proxy-core-other"
    compile_c(fixture, target)
    compile_c(fixture, neighbor)
    children = []

    def spawn(path, stubborn=False):
        p = subprocess.Popen([path] + (["ignore-term"] if stubborn else []), stdout=subprocess.PIPE)
        children.append(p)
        assert p.stdout.readline() == b"ready\n"
        return p

    daemon = None
    try:
        ordinary = spawn(target)
        unrelated = spawn(neighbor)
        rules.write_text(str(target) + "\n")
        output = subprocess.check_output([binary, "--dry-run", rules], text=True)
        assert f"{ordinary.pid}\t{target}" in output
        assert str(neighbor) not in output
        assert ordinary.poll() is None and unrelated.poll() is None
        daemon = subprocess.Popen([runner, rules])
        assert ordinary.wait(timeout=7) == -signal.SIGTERM
        stubborn = spawn(target, True)
        assert stubborn.wait(timeout=10) == -signal.SIGKILL
        restarted = spawn(target)
        assert restarted.wait(timeout=7) == -signal.SIGTERM
        assert unrelated.poll() is None
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
    print("Watchdog checks passed: validation, exact matching, dry run, TERM, KILL, restart, isolation, shutdown")
