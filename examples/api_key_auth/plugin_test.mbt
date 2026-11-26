///|
fn setup() -> @proxytest.HostEmulator {
  let emu = @proxytest.HostEmulator::new(
    plugin_config=b"{\"keys\": {\"k-123\": \"alice\"}}",
  )
  assert_true(emu.start()) catch {
    _ => abort("start failed")
  }
  emu
}

///|
test "valid key is stripped and the consumer is forwarded" {
  let emu = setup()
  let id = emu.init_http()
  inspect(
    emu.call_on_request_headers(id, [(":path", "/"), ("X-Api-Key", "k-123")]),
    content="Continue",
  )
  debug_inspect(
    emu.request_headers(id),
    content=(
      #|[(":path", "/"), ("x-consumer", "alice")]
    ),
  )
  debug_inspect(emu.metric("api_key_auth.allowed"), content="Some(1)")
}

///|
test "missing key gets 401" {
  let emu = setup()
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, [(":path", "/")]), content="Pause")
  inspect(emu.local_response(id).unwrap().status_code, content="401")
  debug_inspect(emu.metric("api_key_auth.denied"), content="Some(1)")
}

///|
test "unknown key gets 403" {
  let emu = setup()
  let id = emu.init_http()
  inspect(
    emu.call_on_request_headers(id, [(":path", "/"), ("x-api-key", "nope")]),
    content="Pause",
  )
  let resp = emu.local_response(id).unwrap()
  inspect(resp.status_code, content="403")
  inspect(
    @utf8.decode_lossy(resp.body),
    content=(
      #|{"error":"invalid api key"}
    ),
  )
}

///|
test "a client cannot smuggle its own x-consumer" {
  let emu = setup()
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [
    ("x-consumer", "admin"),
    ("x-api-key", "k-123"),
  ])
  debug_inspect(
    emu.request_headers(id),
    content="[(\"x-consumer\", \"alice\")]",
  )
}

///|
test "configuration errors reject the plugin" {
  for cfg in [b"", b"{}", b"{\"keys\": {\"a\": 1}}"] {
    let emu = @proxytest.HostEmulator::new(plugin_config=cfg)
    inspect(emu.start(), content="false")
  }
}
