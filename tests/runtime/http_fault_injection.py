#!/usr/bin/env python3
"""Inject oversized and hung loopback responses through Qt XMLHttpRequest."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class FaultServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        self.hits: list[str] = []
        self.hit_lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), FaultHandler)


class FaultHandler(BaseHTTPRequestHandler):
    server: FaultServer

    def do_GET(self) -> None:
        with self.server.hit_lock:
            self.server.hits.append(self.path)
        if self.path == "/hang":
            time.sleep(3.0)
            body = b'{"value":1}'
        elif self.path == "/oversized":
            body = b'{"value":"' + (b"x" * 1_048_576) + b'"}'
        else:
            body = b'{"value":42}'
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args) -> None:
        pass


def test_document(port: int) -> str:
    widgets = (REPO / "ui" / "qml" / "widgets").as_uri()
    return f"""import QtQuick
import QtTest
import "{widgets}" as Widgets

Item {{
    width: 320
    height: 180

    Widgets.NetHub {{ id: hub }}

    TestCase {{
        name: "LiveHttpFaultInjection"
        when: windowShown

        function test_real_oversized_and_hung_responses() {{
            var oversizedError = ""
            var oversizedDone = false
            var oversized = hub.request({{
                url: "http://127.0.0.1:{port}/oversized",
                timeout: 3000,
                maxResponseBytes: 1048576,
                onDone: function () {{ oversizedDone = true }},
                onError: function (reason) {{ oversizedError = reason }}
            }})
            verify(oversized !== null, "oversized request reached Qt XMLHttpRequest")
            tryVerify(function () {{ return oversizedError === "response-too-large" }}, 5000)
            compare(oversizedDone, false, "oversized body never reaches the parser callback")

            var timeoutError = ""
            var timeoutDone = false
            var started = Date.now()
            var hung = hub.request({{
                url: "http://127.0.0.1:{port}/hang",
                timeout: 750,
                onDone: function () {{ timeoutDone = true }},
                onError: function (reason) {{ timeoutError = reason }}
            }})
            verify(hung !== null, "hung request reached Qt XMLHttpRequest")
            tryVerify(function () {{ return timeoutError === "timeout" }}, 3000)
            compare(timeoutDone, false, "hung endpoint never reaches the success callback")
            verify(Date.now() - started >= 600, "timeout was asynchronous, not an immediate fake")
            compare(hub.requests, 2, "both real loopback requests were counted")
        }}
    }}
}}
"""


def main() -> int:
    configured = os.environ.get("XENEON_QMLTESTRUNNER", "")
    candidates = [
        Path(configured) if configured else None,
        REPO / "build" / "xeneon-qmltestrunner",
        Path("/usr/lib/qt6/bin/qmltestrunner"),
    ]
    on_path = shutil.which("qmltestrunner")
    if on_path:
        candidates.append(Path(on_path))
    runner = next(
        (
            str(candidate)
            for candidate in candidates
            if candidate is not None
            and candidate.is_file()
            and os.access(candidate, os.X_OK)
        ),
        None,
    )
    if runner is None:
        print("SKIP: qmltestrunner is unavailable")
        return 77

    server = FaultServer()
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    temporary = Path(tempfile.mkdtemp(prefix="xe-http-fault."))
    test_file = temporary / "tst_live_http_faults.qml"
    test_file.write_text(test_document(server.server_port), encoding="utf-8")
    environment = dict(os.environ)
    environment.update(
        {
            "QT_QPA_PLATFORM": "offscreen",
            "QT_QUICK_BACKEND": "software",
            "QML_DISABLE_DISK_CACHE": "1",
        }
    )
    try:
        result = subprocess.run(
            [runner, "-input", str(test_file), "-o", "-", "txt"],
            cwd=REPO,
            env=environment,
            capture_output=True,
            text=True,
            timeout=15,
        )
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="")
        with server.hit_lock:
            hits = list(server.hits)
        print(f"Loopback hits: {hits}")
        if result.returncode != 0:
            print(f"RESULT: FAILURE - qmltestrunner exited {result.returncode}")
            return 1
        if "/oversized" not in hits or "/hang" not in hits:
            print("RESULT: FAILURE - one or more fault endpoints were not reached")
            return 1
        print("RESULT: SUCCESS - real Qt HTTP faults produced bounded errors")
        return 0
    except subprocess.TimeoutExpired:
        print("RESULT: FAILURE - HTTP fault test exceeded 15 seconds")
        return 1
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2.0)
        shutil.rmtree(temporary, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
