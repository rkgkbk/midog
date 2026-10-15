"""Exercise the bundled core's real file-provider lifecycle; no root, TUN, or system proxy."""
import gzip
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"focus-test-ok")

    def log_message(self, *args):
        pass


with tempfile.TemporaryDirectory(prefix="midog-focus-") as temporary:
    root = Path(temporary)
    core = root / "midog-core"
    with gzip.open(ROOT / "midog/Resources/midog-core.gz", "rb") as source:
        core.write_bytes(source.read())
    core.chmod(0o755)
    data = root / "data"
    rules = root / "system-rules"
    data.mkdir()
    rules.mkdir()
    rule_file = rules / "domains.list"
    rule_file.write_text("midog-focus-empty.invalid\n")
    api, proxy_port = port(), port()
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    config = {
        "mixed-port": proxy_port, "external-controller": f"127.0.0.1:{api}",
        "secret": "focus-test-secret", "mode": "rule", "log-level": "error",
        "ipv6": False, "dns": {"enable": False},
        "hosts": {"focus.test": "127.0.0.1", "sub.focus.test": "127.0.0.1",
                  "notfocus.test": "127.0.0.1", "other.test": "127.0.0.1"},
        "rule-providers": {"__MIDOG_FOCUS": {"type": "file", "behavior": "domain",
                                              "format": "text", "path": str(rule_file)}},
        "rules": ["RULE-SET,__MIDOG_FOCUS,REJECT", "MATCH,DIRECT"],
    }
    (data / "config.yaml").write_text(json.dumps(config))
    environment = dict(os.environ, SAFE_PATHS=str(rules))
    process = None
    log = (root / "core.log").open("w+")

    def request(method, path):
        connection = http.client.HTTPConnection("127.0.0.1", api, timeout=2)
        try:
            connection.request(method, path, headers={"Authorization": "Bearer focus-test-secret"})
            response = connection.getresponse()
            content = response.read()
            assert response.status in (200, 204), (response.status, content)
            return content
        finally:
            connection.close()

    def start():
        global process
        process = subprocess.Popen([str(core), "-d", str(data)], env=environment, stdout=log, stderr=log)
        for _ in range(100):
            assert process.poll() is None, (root / "core.log").read_text()
            try:
                request("GET", "/version")
                return
            except OSError:
                time.sleep(0.05)
        raise AssertionError("Core did not start")

    def reachable(host):
        connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=2)
        try:
            connection.request("GET", f"http://{host}:{origin.server_port}/", headers={"Connection": "close"})
            response = connection.getresponse()
            return response.status == 200 and response.read() == b"focus-test-ok"
        except (OSError, http.client.HTTPException):
            return False
        finally:
            connection.close()

    def publish(contents):
        stage = rules / "next.list"
        stage.write_text(contents)
        stage.replace(rule_file)
        request("PUT", "/providers/rules/__MIDOG_FOCUS")

    try:
        start()
        assert reachable("focus.test"), "Inactive list must allow traffic"
        # Keep a pre-focus tunnel alive: changing routing rules alone cannot close it.
        tunnel = socket.create_connection(("127.0.0.1", proxy_port), timeout=2)
        tunnel.sendall(f"CONNECT focus.test:{origin.server_port} HTTP/1.1\r\nHost: focus.test\r\n\r\n".encode())
        assert b"200" in tunnel.recv(4096)
        time.sleep(0.1)
        existing = json.loads(request("GET", "/connections"))["connections"]
        connection_id = next(c["id"] for c in existing if c["metadata"].get("host") == "focus.test")
        publish("+.focus.test\n")
        request("DELETE", "/connections/" + connection_id.replace("-", "%2D"))
        remaining = json.loads(request("GET", "/connections"))["connections"] or []
        assert any(c["id"] == connection_id for c in remaining), "Confirm encoded-ID no-op regression"
        request("DELETE", "/connections/" + connection_id)
        remaining = json.loads(request("GET", "/connections"))["connections"] or []
        assert not any(c["id"] == connection_id for c in remaining), "Existing tunnel must close"
        tunnel.close()
        assert not reachable("focus.test")
        assert not reachable("sub.focus.test")
        assert reachable("notfocus.test"), "Suffix matching must respect label boundaries"
        assert reachable("other.test")
        publish("+.focus.test\n+.other.test\n")
        assert not reachable("other.test"), "New additions must reload"
        process.terminate()
        process.wait(timeout=5)
        start()
        assert not reachable("focus.test"), "Core restart must retain the active rules"
        publish("midog-focus-empty.invalid\n")
        assert reachable("focus.test"), "Expiry must release traffic without regenerating the core config"
        assert reachable("other.test")
        print("Focus proxy integration passed: block, subdomains, live additions, restart, expiry")
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        origin.shutdown()
        origin.server_close()
        log.close()
