"""Check flow identity without installing an extension or changing the host network."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="midog-proxy-flow-") as directory:
    root = Path(directory)
    source = root / "check.c"
    source.write_text(r'''
#include <assert.h>
#include <mach/mach.h>
#include <stdlib.h>
#include "ProxyFlow.h"
int main(int argc, char **argv) {
    assert(argc == 2);
    audit_token_t token;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    assert(task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &count) == KERN_SUCCESS);
    assert(midog_proxy_flow(&token, sizeof(token)) == (atoi(argv[1]) != 0));
    assert(!midog_proxy_flow(NULL, sizeof(token)));
    assert(!midog_proxy_flow(&token, sizeof(token) - 1));
    // A PID alone must never identify a different incarnation of the process.
    token.val[7]++;
    assert(!midog_proxy_flow(&token, sizeof(token)));
    midog_proxy_cache_clear();
    return 0;
}
''')
    binary = root / "mihomo"
    subprocess.run(["xcrun", "clang", "-std=c17", "-Wall", "-Wextra", "-Werror",
                    "-I", str(ROOT / "midogFilter"), str(source),
                    str(ROOT / "midogFilter/ProxyFlow.c"), "-framework", "CoreFoundation",
                    "-o", str(binary)], check=True)

    def check(path, blocked):
        if path != binary:
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(binary, path)
        subprocess.run([path, str(int(blocked))], check=True)

    check(binary, True)
    check(root / "ordinary-browser", False)
    check(root / "midog-core", False)
    for name, identifier, blocked in [
        ("Renamed.app", "app.hiddify.com", True),
        ("RenamedProxy.app", "com.initex.proxifier.v3.macos", True),
        ("Proxy.systemextension", "com.initex.proxifier.v3.macos.ProxifierExtension", True),
        ("Own.app", "com.xx.midog", False),
        ("Unknown.app", "org.example.unknown", False),
    ]:
        contents = root / name / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        check(contents / "MacOS" / "renamed-helper", blocked)
    print("Passed: real audit tokens, proxy core, renamed bundle, own core, unknown app, malformed and stale tokens")
