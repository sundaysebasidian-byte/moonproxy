///|
test "adds the configured response header and logs the request" {
  let emu = @proxytest.HostEmulator::new(
    plugin_config=b"{\"header\": \"X-Served-By\", \"value\": \"moon\"}",
  )
  assert_true(emu.start())
  let id = emu.init_http()
  inspect(
    emu.call_on_request_headers(id, [(":method", "GET"), (":path", "/hello")]),
    content="Continue",
  )
  inspect(
    emu.call_on_response_headers(id, [(":status", "200")]),
    content="Continue",
  )
  debug_inspect(
    emu.response_headers(id),
    content=(
      #|[(":status", "200"), ("x-served-by", "moon")]
    ),
  )
  debug_inspect(emu.logs(level=Info), content="[\"GET /hello\"]")
}

///|
test "defaults without configuration" {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start())
  let id = emu.init_http()
  let _ = emu.call_on_response_headers(id, [(":status", "204")])
  debug_inspect(
    emu.response_headers(id),
    content=(
      #|[(":status", "204"), ("x-powered-by", "moonproxy")]
    ),
  )
}

///|
test "invalid configuration is rejected" {
  let emu = @proxytest.HostEmulator::new(plugin_config=b"{not json")
  inspect(emu.start(), content="false")
}
