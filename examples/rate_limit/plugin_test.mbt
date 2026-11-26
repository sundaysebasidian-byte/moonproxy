///|
fn start(cfg : String) -> @proxytest.HostEmulator {
  let cfg = cfg[:cfg.length() - 1].to_owned() +
    ", \"key_header\": \"x-client-id\"}"
  let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(cfg))
  assert_true(emu.start()) catch {
    _ => abort("start failed")
  }
  emu
}

///|
fn hit(emu : @proxytest.HostEmulator, client : String) -> @moonproxy.Action {
  let id = emu.init_http()
  emu.call_on_request_headers(id, [(":path", "/"), ("x-client-id", client)])
}

///|
test "burst is honoured, then requests are limited" {
  let emu = start("{\"rate_per_second\": 2, \"burst\": 3}")
  let got = (0).until(5).map(fn(_) { hit(emu, "a").to_string() }).collect()
  debug_inspect(
    got,
    content=(
      #|["Continue", "Continue", "Continue", "Pause", "Pause"]
    ),
  )
  debug_inspect(emu.metric("rate_limit.limited"), content="Some(2)")
}

///|
test "clients have separate buckets" {
  let emu = start("{\"rate_per_second\": 1, \"burst\": 1}")
  inspect(hit(emu, "a"), content="Continue")
  inspect(hit(emu, "a"), content="Pause")
  inspect(hit(emu, "b"), content="Continue")
}

///|
test "tokens refill over time and retry-after is reported" {
  let emu = start("{\"rate_per_second\": 2, \"burst\": 1}")
  let t0 = 1_800_000_000_000_000_000L
  emu.set_time_nanos(t0)
  inspect(hit(emu, "c"), content="Continue")
  let id = emu.init_http()
  inspect(
    emu.call_on_request_headers(id, [("x-client-id", "c")]),
    content="Pause",
  )
  let resp = emu.local_response(id).unwrap()
  inspect(resp.status_code, content="429")
  debug_inspect(resp.headers[0], content="(\"retry-after\", \"1\")")
  // 2 tokens/s: one token is back after 500 ms.
  emu.set_time_nanos(t0 + 499_000_000L)
  inspect(hit(emu, "c"), content="Pause")
  emu.set_time_nanos(t0 + 1_000_000_000L)
  inspect(hit(emu, "c"), content="Continue")
}

///|
test "a corrupted bucket is reset instead of crashing" {
  let emu = start("{\"rate_per_second\": 1, \"burst\": 1}")
  for i in 0..<4096 {
    @moonproxy.set_shared_data("rate_limit:\{i}", b"garbage")
  }
  inspect(hit(emu, "z"), content="Continue")
}

///|
test "configuration is validated" {
  for
    cfg in [
      "{}", "{\"rate_per_second\": 0}", "{\"rate_per_second\": 1.5}", "{\"rate_per_second\": 1, \"burst\": -1}",
    ] {
    let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(cfg))
    inspect(emu.start(), content="false")
  }
}

///|
test "a lost CAS race is retried, so no token is spent twice" {
  let emu = start("{\"rate_per_second\": 1, \"burst\": 2}")
  emu.set_time_nanos(1_800_000_000_000_000_000L)
  inspect(hit(emu, "r"), content="Continue")
  // Another worker writes the bucket three times while this request runs.
  emu.fail_next_cas(3)
  inspect(hit(emu, "r"), content="Continue")
  inspect(hit(emu, "r"), content="Pause")
}

///|
test "endless CAS conflicts fail open with a warning" {
  let emu = start("{\"rate_per_second\": 1, \"burst\": 1}")
  inspect(hit(emu, "w"), content="Continue")
  emu.fail_next_cas(1000)
  inspect(hit(emu, "w"), content="Continue")
  let warned = emu
    .logs()
    .iter()
    .any(fn(l) { l.contains("CAS retries exhausted") })
  inspect(warned, content="true")
}

///|
test "without key_header clients are told apart by source IP, not headers" {
  let emu = @proxytest.HostEmulator::new(
    plugin_config=b"{\"rate_per_second\": 1, \"burst\": 1}",
  )
  assert_true(emu.start()) catch {
    _ => abort("start failed")
  }
  let from = fn(addr : String, forged : String) {
    emu.set_property(["source", "address"], @utf8.encode(addr))
    let id = emu.init_http()
    emu.call_on_request_headers(id, [(":path", "/"), ("x-client-id", forged)])
  }
  inspect(from("10.0.0.1:1000", "a"), content="Continue")
  // A new port or a made-up header does not buy a new bucket.
  inspect(from("10.0.0.1:2000", "b"), content="Pause")
  inspect(from("10.0.0.2:1000", "c"), content="Continue")
}

///|
test "buckets is validated" {
  for
    cfg in [
      "{\"rate_per_second\": 1, \"buckets\": 0}", "{\"rate_per_second\": 1, \"buckets\": 2000000}",
    ] {
    let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(cfg))
    inspect(emu.start(), content="false")
  }
}
