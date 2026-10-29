#!/usr/bin/env python3
"""Local-only CLI integration checks; no third-party Python packages required."""
from __future__ import annotations

import errno
import http.server
import os
from pathlib import Path
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def bash_executable() -> str:
    candidates = [os.environ.get("BASHBOARD_TEST_BASH", "")]
    if os.name == "nt":
        candidates += [r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"]
    candidates += [shutil.which("bash") or ""]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise RuntimeError("Bash is required")


def shell_path(path: Path) -> str:
    return str(path).replace("\\", "/")


def write_config(path: Path, rows: list[tuple[str, int, str]]) -> None:
    path.write_text("name\thost\tport\tprotocol\n" + "".join(
        f"{name}\t127.0.0.1\t{port}\t{protocol}\n" for name, port, protocol in rows
    ), encoding="utf-8")


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


class LocalServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.errors: list[str] = []

    def handle_error(self, request: object, client_address: object) -> None:
        # A client deliberately times out or rejects our self-signed certificate.
        exception = sys.exc_info()[1]
        if isinstance(exception, ConnectionError):
            return
        self.errors.append(repr(exception))
        super().handle_error(request, client_address)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        server = self.server
        server.hits += 1
        if server.delay:
            time.sleep(server.delay)
        try:
            self.send_response(server.code)
            if server.code == 302:
                self.send_header("Location", "http://127.0.0.1:1/")
            self.end_headers()
            self.wfile.write(b"BashBoard local test\n")
        except ConnectionError:
            pass

    def log_message(self, *_args: object) -> None:
        pass


def interactive_interrupt(bash: str, config: Path, env: dict[str, str], runtime: Path) -> None:
    if os.name == "nt":
        print("SKIP: foreground Ctrl+C/PTY check is Linux-only")
        return
    import fcntl
    import pty
    import struct
    import termios

    args = [bash, shell_path(ROOT / "bashboard.sh"), "--config", shell_path(config),
            "--interval", "3600", "--timeout", "2", "--jobs", "1"]
    tty_env = dict(env, TERM="xterm-256color", COLUMNS="100", LINES="24")
    pid, master = pty.fork()
    if pid == 0:
        os.execve(bash, args, tty_env)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    os.set_blocking(master, False)
    data = bytearray()
    finished = False
    try:
        deadline = time.monotonic() + 20
        sent_interrupt = False
        while time.monotonic() < deadline:
            try:
                chunk = os.read(master, 65536)
                data.extend(chunk)
            except BlockingIOError:
                pass
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
            if b"TCP_CLOSED" in data and not sent_interrupt:
                os.write(master, b"\x03")
                sent_interrupt = True
            child, status = os.waitpid(pid, os.WNOHANG)
            if child:
                finished = True
                # Drain the restoration sequences written immediately before exit.
                try:
                    while True:
                        chunk = os.read(master, 65536)
                        if not chunk:
                            break
                        data.extend(chunk)
                except (BlockingIOError, OSError):
                    pass
                check(os.waitstatus_to_exitcode(status) == 130,
                      f"Ctrl+C exit was {os.waitstatus_to_exitcode(status)}: {data!r}")
                break
            time.sleep(0.025)
        check(finished, f"interactive dashboard did not exit: {data!r}")
        check(b"\x1b[?25h" in data and b"\x1b[?1049l" in data, "cursor/screen not restored")
        check(not list(runtime.glob("bashboard.*")), "interactive temporary directory leaked")
        print("PASS: real terminal frame, Ctrl+C, cursor restoration, and pause cleanup")
    finally:
        if not finished:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
        os.close(master)


def main() -> None:
    bash = bash_executable()
    with tempfile.TemporaryDirectory(prefix="bashboard-integration-") as temporary:
        scratch = Path(temporary)
        runtime = scratch / "runtime with spaces"
        runtime.mkdir()
        env = dict(os.environ, TMPDIR=shell_path(runtime), NO_PROXY="*", no_proxy="*")
        tcp_tool = "ncat.exe" if os.name == "nt" else "nc"
        has_tcp = subprocess.run([bash, "-c", f"command -v {tcp_tool}"], env=env,
                                 capture_output=True).returncode == 0
        # A bound but non-listening socket reserves a reliably closed local TCP port.
        with socket.socket() as closed:
            closed.bind(("127.0.0.1", 0))
            closed_port = closed.getsockname()[1]
            closed_config = scratch / "closed.tsv"
            write_config(closed_config, [("TCP_CLOSED", closed_port, "tcp")])
            interactive_interrupt(bash, closed_config, env, runtime)

            servers: list[http.server.ThreadingHTTPServer] = []

            def server(code: int, delay: float = 0) -> http.server.ThreadingHTTPServer:
                instance = LocalServer(("127.0.0.1", 0), Handler)
                instance.daemon_threads = True
                instance.code, instance.delay, instance.hits = code, delay, 0
                servers.append(instance)
                threading.Thread(target=instance.serve_forever, daemon=True).start()
                return instance

            try:
                ok, failed, redirect, slow = server(200), server(503), server(302), server(200, 5)
                rows = [
                    ("HTTP_OK long name %", ok.server_port, "http"),
                    ("HTTP_503", failed.server_port, "http"),
                    ("REDIRECT", redirect.server_port, "http"),
                    ("TCP_CLOSED", closed_port, "tcp"),
                    ("HTTP_TIMEOUT", slow.server_port, "http"),
                ]
                openssl_candidates = [shutil.which("openssl") or ""]
                if os.name == "nt":
                    openssl_candidates += [r"C:\Program Files\Git\usr\bin\openssl.exe",
                                           r"C:\Program Files\Git\mingw64\bin\openssl.exe"]
                openssl = next((p for p in openssl_candidates if p and Path(p).is_file()), None)
                if openssl:
                    cert, key = scratch / "cert.pem", scratch / "key.pem"
                    subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                                    "-keyout", str(key), "-out", str(cert), "-days", "1",
                                    "-subj", "/CN=localhost"], check=True, capture_output=True)
                    tls = LocalServer(("127.0.0.1", 0), Handler)
                    tls.code, tls.delay, tls.hits = 200, 0, 0
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.load_cert_chain(cert, key)
                    tls.socket = context.wrap_socket(tls.socket, server_side=True)
                    servers.append(tls)
                    threading.Thread(target=tls.serve_forever, daemon=True).start()
                    rows.append(("TLS_UNTRUSTED", tls.server_port, "https"))
                else:
                    print("SKIP: real self-signed TLS check (openssl not installed)")

                config = scratch / "services with spaces.tsv"
                write_config(config, rows)

                def run(*arguments: str) -> subprocess.CompletedProcess[str]:
                    return subprocess.run([bash, shell_path(ROOT / "bashboard.sh"), *arguments],
                                          env=env, capture_output=True, text=True, timeout=30)

                initial_hits = sum(s.hits for s in servers)
                validation = run("--check-config", shell_path(config))
                check(validation.returncode == 0, validation.stderr)
                check(sum(s.hits for s in servers) == initial_hits, "config validation made requests")

                result = run("--once", "--plain", "--timeout", "2", "--jobs", "4", shell_path(config))
                expected_exit = 1 if has_tcp else 2
                check(result.returncode == expected_exit, f"expected exit {expected_exit}, got {result.returncode}\n{result.stdout}\n{result.stderr}")
                check("\x1b" not in result.stdout, "plain output contains terminal escapes")
                positions = []
                for name, _port, _protocol in rows:
                    line = next((line for line in result.stdout.splitlines() if line.startswith(name)), "")
                    check(bool(line), f"missing row {name}\n{result.stdout}")
                    expected = "UP" if name.startswith("HTTP_OK") or name == "REDIRECT" else "DOWN"
                    if name == "TCP_CLOSED" and not has_tcp:
                        expected = "ERROR"
                    check(expected in line, f"wrong state: {line}")
                    positions.append(result.stdout.index(name))
                check(positions == sorted(positions), "CLI reordered service rows")
                for detail in ["HTTP 200", "HTTP 503", "HTTP 302", "Timed out"]:
                    check(detail in result.stdout, f"missing detail {detail}: {result.stdout}")
                if openssl:
                    check("TLS check failed" in result.stdout, "self-signed certificate was not rejected")
                if not has_tcp:
                    check(f"Missing {tcp_tool}" in result.stdout, "missing TCP tool was not diagnosed")
                check(not list(runtime.glob("bashboard.*")), "one-shot temporary directory leaked")
                print("PASS: local HTTP 200/503/302, TCP state, deadline, TLS, stable rows, and cleanup")

                healthy = scratch / "healthy.tsv"
                write_config(healthy, [("HEALTHY", ok.server_port, "http")])
                # No --once: redirected stdout must still finish after one snapshot.
                healthy_result = run("--timeout", "2", shell_path(healthy))
                check(healthy_result.returncode == 0, healthy_result.stdout + healthy_result.stderr)
                check(healthy_result.stdout.count("BashBoard v1.0") == 1, "redirected stdout repeated")
                launcher = subprocess.run([bash, shell_path(ROOT / "bashboard"), "--version"],
                                          env=env, capture_output=True, text=True, timeout=10)
                check(launcher.returncode == 0 and "BashBoard 1.0" in launcher.stdout, launcher.stderr)
                check(not any(s.errors for s in servers), "unexpected local fixture server error")
                print("PASS: healthy exit 0, redirected one-shot output, and launcher")
            finally:
                for instance in servers:
                    instance.shutdown()
                    instance.server_close()
    print("All local integration checks passed.")


if __name__ == "__main__":
    main()
