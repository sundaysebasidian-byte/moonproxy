#!/usr/bin/env python3
"""Throughput and latency of the same plugin written with moonproxy and with
the official proxy-wasm Rust SDK, both inside one Envoy, against a no-plugin
baseline. Requires docker and wrk.

Every listener answers with an Envoy `direct_response`, so no backend
process takes part and the numbers measure Envoy plus the plugin only. The
three cases run in rotating order for BENCH_ROUNDS rounds; the table shows
the median and the min-max spread of requests per second across rounds.

Usage: python3 bench/run.py <moonproxy http_headers.wasm> <rust_headers.wasm>
"""
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
import envoy_config as ec  # noqa: E402
from run import IMAGE, wait_ready  # noqa: E402

CONFIG = {"header": "x-powered-by", "value": "bench"}
DURATION = os.environ.get("BENCH_DURATION", "10s")
ROUNDS = int(os.environ.get("BENCH_ROUNDS", "5"))
CONNECTIONS = os.environ.get("BENCH_CONNECTIONS", "32")


def wrk(port):
    out = subprocess.run(
        ["wrk", "-t2", f"-c{CONNECTIONS}", f"-d{DURATION}", "--latency", f"http://127.0.0.1:{port}/hello"],
        capture_output=True, text=True, check=True).stdout
    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
    lat = {p: re.search(rf"^\s+{p}%\s+(\S+)", out, re.M).group(1) for p in ("50", "99")}
    errors = re.search(r"Non-2xx or 3xx responses: (\d+)", out)
    return rps, lat, int(errors.group(1)) if errors else 0


def main():
    moon_wasm, rust_wasm = (os.path.abspath(p) for p in sys.argv[1:3])
    work = tempfile.mkdtemp()
    os.chmod(work, 0o755)  # the envoy user in the container must read the config
    for src, dst in ((moon_wasm, "moonproxy.wasm"), (rust_wasm, "rust.wasm")):
        with open(src, "rb") as a, open(os.path.join(work, dst), "wb") as b:
            b.write(a.read())
    cases = [("no plugin", 10101, None), ("moonproxy (MoonBit)", 10102, "/w/moonproxy.wasm"),
             ("proxy-wasm Rust SDK", 10103, "/w/rust.wasm")]
    listeners = [ec.http_listener(f"l{port}", port, path, CONFIG, direct_response="hello")
                 for _, port, path in cases]
    with open(os.path.join(work, "envoy.json"), "w") as f:
        json.dump(ec.bootstrap(listeners), f)
    envoy = subprocess.Popen(
        ["docker", "run", "--rm", "--name", "moonproxy-bench", "--network", "host",
         "-v", f"{work}:/w:ro", IMAGE, "envoy", "-c", "/w/envoy.json", "--concurrency", "2",
         "--component-log-level", "wasm:warn"],
        stdout=subprocess.DEVNULL, stderr=open(os.path.join(work, "envoy.log"), "w"))
    results = {name: [] for name, _, _ in cases}
    try:
        if not wait_ready():
            subprocess.run(["docker", "stop", "-t", "2", "moonproxy-bench"], capture_output=True)
            sys.exit("envoy did not start:\n" + open(os.path.join(work, "envoy.log")).read()[-3000:])
        for name, port, _ in cases:
            subprocess.run(["wrk", "-t2", "-c8", "-d3s", f"http://127.0.0.1:{port}/hello"],
                           capture_output=True, check=True)  # warm up JIT and connections
        for r in range(ROUNDS):
            order = cases[r % len(cases):] + cases[:r % len(cases)]
            for name, port, _ in order:
                results[name].append(wrk(port))
                time.sleep(1)
    finally:
        subprocess.run(["docker", "stop", "-t", "2", "moonproxy-bench"], capture_output=True)
        envoy.wait(timeout=30)

    def ms(v):
        m = re.match(r"([\d.]+)(us|ms|s)", v)
        return float(m.group(1)) * {"us": 0.001, "ms": 1, "s": 1000}[m.group(2)]

    rows = []
    for name, _, path in cases:
        runs = results[name]
        rps = [x[0] for x in runs]
        size = os.path.getsize(os.path.join(work, path.split("/")[-1])) if path else None
        rows.append((name, statistics.median(rps), min(rps), max(rps),
                     statistics.median(ms(x[1]["50"]) for x in runs),
                     statistics.median(ms(x[1]["99"]) for x in runs),
                     sum(x[2] for x in runs), size))
    base = rows[0][1]
    table = ["| plugin | req/s (median) | min-max | vs no plugin | p50 | p99 | non-2xx | .wasm size |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for name, rps, lo, hi, p50, p99, errors, size in rows:
        table.append(f"| {name} | {rps:,.0f} | {lo:,.0f}-{hi:,.0f} | {rps / base:.1%} | {p50:.2f} ms | "
                     f"{p99:.2f} ms | {errors} | {'-' if size is None else f'{size / 1024:.1f} KiB'} |")
    text = "\n".join(table)
    print(text)
    if any(r[6] for r in rows):
        sys.exit("some requests failed")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(f"### Benchmark (wrk -t2 -c{CONNECTIONS} -d{DURATION} x {ROUNDS} rounds, "
                    f"Envoy --concurrency 2, direct_response)\n\n{text}\n")

if __name__ == "__main__":
    main()
