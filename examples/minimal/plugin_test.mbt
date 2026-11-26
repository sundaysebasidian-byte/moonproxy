///|
test "rejects requests without a key" {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start())
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, [(":path", "/")]), content="Pause")
  guard emu.local_response(id) is Some(r) else { fail("expected 401") }
  inspect(r.status_code, content="401")
}

///|
test "marks requests that carry a key" {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start())
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, [("x-api-key", "k")]), content="Continue")
  debug_inspect(
    emu.request_headers(id),
    content=(
      #|[("x-api-key", "k"), ("x-checked-by", "moonbit")]
    ),
  )
}
