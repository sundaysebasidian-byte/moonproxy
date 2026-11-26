"""Loopback backends used by the Envoy end-to-end test and the benchmark.

- 8081 echo: answers JSON describing the request it received
  (`/pii` streams a body with personal data in two chunks instead;
  `/__seen` lists every request received so far);
- 8082 auth: `/check` allows `authorization: Bearer good` (200 with
  `x-user-id: u-1`), denies anything else with 403;
- 8083 TCP echo.
"""
import json
import socketserver
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SEEN = []  # (method, path) of every request the echo backend received


class Echo(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        if "chunked" in (self.headers.get("transfer-encoding") or "").lower():
            raw = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass  # trailers
                    return raw
                raw += self.rfile.read(size)
                self.rfile.readline()
        n = int(self.headers.get("content-length") or 0)
        return self.rfile.read(n) if n else b""

    def _handle(self):
        # Record the request as soon as its headers arrive: a filter that
        # lets headers through but rejects the body must still show up.
        if self.path != "/__seen":
            SEEN.append([self.command, self.path])
        raw = self._read_body()
        n = len(raw)
        body = raw.decode("utf-8", "replace")
        if self.path == "/__seen":
            self._send(200, json.dumps(SEEN))
            return
        if self.path == "/pii":
            # Chunked on purpose: the phone number straddles two chunks.
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()
            for part in ('{"user":"alice@example.com","tel":"138123', '45678"}'):
                raw = part.encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(raw), raw))
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"0\r\n\r\n")
            return
        if self.path == "/hello":
            self._send(200, "hello", "text/plain")
            return
        self._send(200, json.dumps({
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
            "body_bytes": n,
        }))

    do_GET = do_POST = do_PUT = _handle


class Auth(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        ok = self.headers.get("authorization") == "Bearer good"
        body = b"" if ok else b'{"error":"bad token"}'
        self.send_response(200 if ok else 403)
        if ok:
            self.send_header("x-user-id", "u-1")
        else:
            self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class TcpEcho(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


class ThreadingTCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def start():
    servers = [
        ThreadingHTTPServer(("127.0.0.1", 8081), Echo),
        ThreadingHTTPServer(("127.0.0.1", 8082), Auth),
        ThreadingTCP(("127.0.0.1", 8083), TcpEcho),
    ]
    for s in servers:
        s.daemon_threads = True
        threading.Thread(target=s.serve_forever, daemon=True).start()
    return servers


if __name__ == "__main__":
    start()
    print("backends on 8081 (echo), 8082 (auth), 8083 (tcp echo)")
    threading.Event().wait()
