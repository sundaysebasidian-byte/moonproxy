#!/usr/bin/env python3
"""End-to-end test: the example plugins, compiled by moon to wasm, running
inside a real Envoy (docker, 4 worker threads) against loopback backends.

Usage: python3 e2e/run.py <dir with <plugin>.wasm files> [--image IMAGE]
"""
import argparse
import concurrent.futures
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
import backends  # noqa: E402
import envoy_config as ec  # noqa: E402

IMAGE = "envoyproxy/envoy:v1.34.1"

PLUGINS = {
    # name: (port, config)
    "http_headers": (10001, {"header": "x-powered-by", "value": "moonproxy-e2e"}),
    "api_key_auth": (10002, {"header": "x-api-key", "keys": {"k-1": "alice"}}),
    "rate_limit": (10003, {"rate_per_second": 1, "burst": 5, "key_header": "x-client"}),
    "pii_mask": (10004, {}),
    "ext_authz": (10005, {"cluster": "authz", "authority": "authz", "path": "/check",
                          "timeout_ms": 1000, "forward": ["authorization"],
                          "copy_back": ["x-user-id"]}),
    "ai_guard": (10006, {"allowed_models": ["gpt-4o-mini"], "deny_words": ["internal-only"],
                         "max_tokens": 256}),
    "minimal": (10008, {}),
}
TCP_PORT = 10007
# A second ext_authz instance whose auth cluster is down, with fail_open.
AUTHZ_OPEN_PORT = 10009

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))


def request(port, path, method="GET", headers=None, body=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=body,
                                 method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, dict((k.lower(), v) for k, v in r.headers.items()), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict((k.lower(), v) for k, v in e.headers.items()), e.read()


def wait_ready(timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{ec.ADMIN_PORT}/ready", timeout=1) as r:
                if r.read().strip() == b"LIVE":
                    return True
        except OSError:
            pass
        time.sleep(0.5)
    return False


def stats():
    with urllib.request.urlopen(f"http://127.0.0.1:{ec.ADMIN_PORT}/stats?filter=wasmcustom", timeout=5) as r:
        out = {}
        for line in r.read().decode().splitlines():
            k, _, v = line.partition(": ")
            out[k.strip()] = v.strip()
        return out


def test_http_headers():
    port = PLUGINS["http_headers"][0]
    status, headers, body = request(port, "/hello")
    check("http_headers: request passes", status == 200 and body == b"hello", status)
    check("http_headers: response header set", headers.get("x-powered-by") == "moonproxy-e2e", headers)


def test_api_key_auth():
    port = PLUGINS["api_key_auth"][0]
    status, headers, _ = request(port, "/x")
    check("api_key_auth: missing key is 401", status == 401 and "www-authenticate" in headers, status)
    status, _, _ = request(port, "/x", headers={"x-api-key": "nope"})
    check("api_key_auth: unknown key is 403", status == 403, status)
    status, _, body = request(port, "/x", headers={"x-api-key": "k-1", "x-consumer": "forged"})
    seen = json.loads(body)["headers"] if status == 200 else {}
    check("api_key_auth: key stripped before upstream", status == 200 and "x-api-key" not in seen, seen)
    check("api_key_auth: consumer header replaced", seen.get("x-consumer") == "alice", seen)


def test_rate_limit():
    port = PLUGINS["rate_limit"][0]

    def one(_):
        return request(port, "/r", headers={"x-client": "c1"})[0]

    # The first write of a bucket cannot be a compare-and-swap (proxy-wasm
    # CAS 0 always wins), so create it with one request first. After that
    # every update is a CAS and the burst of 5 must hold exactly.
    first = one(0)
    # 39 concurrent requests spread over Envoy's 4 workers, one shared bucket.
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        codes = [first] + list(pool.map(one, range(39)))
    ok = codes.count(200)
    limited = codes.count(429)
    # One token may refill (1/s) while the batch runs.
    check("rate_limit: burst of 5 shared by all workers", 5 <= ok <= 6 and ok + limited == 40,
          f"200 x{ok}, 429 x{limited}")
    retry = [request(port, "/r", headers={"x-client": "c1"})[1] for _ in range(3)]
    check("rate_limit: 429 carries retry-after", any("retry-after" in h for h in retry), retry)
    status, _, _ = request(port, "/r", headers={"x-client": "other"})
    check("rate_limit: other clients unaffected", status == 200, status)


def test_pii_mask():
    port = PLUGINS["pii_mask"][0]
    status, _, body = request(port, "/pii")
    check("pii_mask: chunked response masked",
          status == 200 and body == b'{"user":"a****@example.com","tel":"138****5678"}', body)
    status, _, body = request(port, "/x", headers={"accept-encoding": "gzip"})
    seen = json.loads(body)["headers"] if status == 200 else {}
    check("pii_mask: upstream never asked for compression", status == 200 and "accept-encoding" not in seen, seen)


def test_ext_authz():
    port = PLUGINS["ext_authz"][0]
    status, _, body = request(port, "/orders", headers={"authorization": "Bearer good",
                                                        "x-user-id": "forged"})
    seen = json.loads(body)["headers"] if status == 200 else {}
    check("ext_authz: allowed request gets identity", status == 200 and seen.get("x-user-id") == "u-1",
          (status, seen))
    status, _, body = request(port, "/orders", headers={"authorization": "Bearer bad"})
    check("ext_authz: denial passed through", status == 403 and b"bad token" in body, (status, body))


def seen_by_backend():
    with urllib.request.urlopen("http://127.0.0.1:8081/__seen", timeout=5) as r:
        return [tuple(x) for x in json.loads(r.read())]


def test_ext_authz_body():
    port = PLUGINS["ext_authz"][0]
    payload = json.dumps({"amount": 100}).encode()
    status, _, _ = request(port, "/transfer-denied", "POST",
                           {"authorization": "Bearer bad", "content-type": "application/json"}, payload)
    time.sleep(0.3)
    reached = ("POST", "/transfer-denied") in seen_by_backend()
    check("ext_authz: denied POST body never reaches the upstream", status == 403 and not reached,
          (status, reached))
    status, _, body = request(port, "/transfer-ok", "POST",
                              {"authorization": "Bearer good", "content-type": "application/json"}, payload)
    seen = json.loads(body) if status == 200 else {}
    check("ext_authz: allowed POST body forwarded intact", seen.get("body") == payload.decode(), seen)


def test_ext_authz_fail_open():
    status, _, body = request(AUTHZ_OPEN_PORT, "/open", headers={"x-user-id": "forged"})
    seen = json.loads(body)["headers"] if status == 200 else {}
    check("ext_authz: fail open passes the request", status == 200, status)
    check("ext_authz: fail open strips forged identity", "x-user-id" not in seen, seen)


def test_minimal():
    port = PLUGINS["minimal"][0]
    status, _, _ = request(port, "/m")
    check("minimal (README example): no key is 401", status == 401, status)
    status, _, body = request(port, "/m", headers={"x-api-key": "k"})
    seen = json.loads(body)["headers"] if status == 200 else {}
    check("minimal (README example): request marked", seen.get("x-checked-by") == "moonbit", seen)


def test_ai_guard():
    port = PLUGINS["ai_guard"][0]
    hdrs = {"content-type": "application/json"}
    req = {"model": "gpt-4o-mini", "max_tokens": 4000,
           "messages": [{"role": "user", "content": "hi"}]}
    status, _, body = request(port, "/v1/chat/completions", "POST", hdrs, json.dumps(req).encode())
    seen = json.loads(body) if status == 200 else {}
    fwd = json.loads(seen.get("body") or "{}")
    check("ai_guard: max_tokens capped upstream", fwd.get("max_tokens") == 256, seen)
    check("ai_guard: rewritten body arrives whole",
          seen.get("body_bytes") == len((seen.get("body") or "").encode()) and fwd.get("model") == "gpt-4o-mini",
          seen)
    req["model"] = "gpt-5"
    status, _, body = request(port, "/v1/chat/completions", "POST", hdrs, json.dumps(req).encode())
    check("ai_guard: disallowed model is 400", status == 400 and b"policy_violation" in body, (status, body))
    # Path tricks and other LLM endpoints must not skip the check.
    for path in ("/v1/Chat//complet%69ons/", "/v1/responses"):
        status, _, body = request(port, path, "POST", hdrs, json.dumps(req).encode())
        check(f"ai_guard: {path} is checked", status == 400, (status, body))


def test_tcp_quota():
    with socket.create_connection(("127.0.0.1", TCP_PORT), timeout=5) as s:
        s.sendall(b"ping")
        check("tcp_quota: data relayed", s.recv(16) == b"ping")
    with socket.create_connection(("127.0.0.1", TCP_PORT), timeout=5) as s:
        closed = False
        try:
            for _ in range(10):
                s.sendall(b"x" * 64)
                if s.recv(4096) == b"":
                    closed = True
                    break
        except socket.timeout:
            closed = False  # still open, just silent: that is a failure
        except OSError:
            closed = True  # reset by the proxy
        check("tcp_quota: connection over quota closed", closed)


def test_metrics():
    st = stats()
    want = ["wasmcustom.api_key_auth.allowed", "wasmcustom.rate_limit.limited",
            "wasmcustom.pii_mask.masked_responses", "wasmcustom.ext_authz.denied",
            "wasmcustom.ai_guard.allowed", "wasmcustom.tcp_quota.closed"]
    missing = [k for k in want if int(st.get(k, "0") or 0) < 1]
    check("metrics: plugin counters exported through Envoy stats", not missing, missing)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wasm_dir")
    ap.add_argument("--image", default=IMAGE)
    args = ap.parse_args()
    wasm_dir = os.path.abspath(args.wasm_dir)
    listeners = [ec.http_listener(n, port, f"/plugins/{n}.wasm", cfg) for n, (port, cfg) in PLUGINS.items()]
    listeners.append(ec.tcp_listener("tcp_quota", TCP_PORT, "/plugins/tcp_quota.wasm", {"max_bytes": 256}))
    listeners.append(ec.http_listener("ext_authz_open", AUTHZ_OPEN_PORT, "/plugins/ext_authz.wasm",
                                      {"cluster": "authz_down", "authority": "authz", "timeout_ms": 500,
                                       "copy_back": ["x-user-id"], "fail_open": True}))
    backends.start()
    work = tempfile.mkdtemp()
    os.chmod(work, 0o755)  # Envoy runs as an unprivileged user in the image
    with open(os.path.join(work, "envoy.json"), "w") as f:
        json.dump(ec.bootstrap(listeners), f, indent=1)
    log = open(os.path.join(work, "envoy.log"), "w")
    cmd = ["docker", "run", "--rm", "--name", "moonproxy-e2e", "--network", "host",
           "-v", f"{wasm_dir}:/plugins:ro", "-v", f"{work}:/cfg:ro", args.image,
           "envoy", "-c", "/cfg/envoy.json", "--concurrency", "4",
           "--component-log-level", "wasm:info"]
    envoy = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_ready():
            check("envoy started with all plugins loaded", False)
        else:
            check("envoy started with all plugins loaded", True)
            for t in (test_http_headers, test_api_key_auth, test_rate_limit, test_pii_mask,
                      test_ext_authz, test_ext_authz_body, test_ext_authz_fail_open, test_ai_guard,
                      test_tcp_quota, test_minimal, test_metrics):
                try:
                    t()
                except Exception as e:  # report and continue with the other plugins
                    check(t.__name__, False, repr(e))
    finally:
        subprocess.run(["docker", "stop", "-t", "2", "moonproxy-e2e"], capture_output=True)
        envoy.wait(timeout=30)
        log.close()
    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("---- envoy log (tail) ----")
        with open(os.path.join(work, "envoy.log")) as f:
            print("".join(f.readlines()[-80:]))
        sys.exit(1)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("### Envoy end-to-end\n\n| check | result |\n|---|---|\n")
            for name, ok, _ in RESULTS:
                f.write(f"| {name} | {'pass' if ok else 'FAIL'} |\n")


if __name__ == "__main__":
    main()
