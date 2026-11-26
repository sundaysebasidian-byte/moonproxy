///|
let config : String =
  #|{"cluster":"authz","authority":"authz.internal","path":"/check",
  #| "timeout_ms":300,"forward":["Authorization"],"copy_back":["x-user-id"]}

///|
fn setup(cfg~ : String = config) -> @proxytest.HostEmulator {
  let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(cfg), clusters=[
    "authz",
  ])
  assert_true(emu.start()) catch {
    _ => abort("start")
  }
  emu
}

///|
fn request(emu : @proxytest.HostEmulator) -> Int32 raise {
  let id = emu.init_http()
  let a = emu.call_on_request_headers(id, [
    (":method", "POST"),
    (":path", "/orders?x=1"),
    ("authorization", "Bearer t"),
    ("x-user-id", "forged"),
  ])
  inspect(a, content="Pause")
  id
}

///|
test "the callout carries the original request" {
  let emu = setup()
  let _ = request(emu)
  let call = emu.http_calls()[0]
  inspect(call.upstream, content="authz")
  inspect(call.timeout_ms, content="300")
  debug_inspect(
    call.headers,
    content=(
      #|[
      #|  (":method", "GET"),
      #|  (":path", "/check"),
      #|  (":authority", "authz.internal"),
      #|  ("x-original-method", "POST"),
      #|  ("x-original-uri", "/orders?x=1"),
      #|  ("authorization", "Bearer t"),
      #|]
    ),
  )
}

///|
test "allow: identity is copied back and the forged one dropped" {
  let emu = setup()
  let id = request(emu)
  let token = emu.http_calls()[0].token
  emu.call_on_http_call_response(
    token,
    [(":status", "200"), ("x-user-id", "u-42")],
    b"",
  )
  inspect(emu.request_resumes(id), content="1")
  debug_inspect(
    emu.request_headers(id).filter(fn(kv) { kv.0 == "x-user-id" }),
    content=(
      #|[("x-user-id", "u-42")]
    ),
  )
  debug_inspect(emu.metric("ext_authz.allowed"), content="Some(1)")
}

///|
test "deny: the service's status and body reach the client" {
  let emu = setup()
  let id = request(emu)
  emu.call_on_http_call_response(
    emu.http_calls()[0].token,
    [(":status", "403"), ("content-type", "application/json")],
    b"{\"error\":\"no access\"}",
  )
  guard emu.local_response(id) is Some(r) else { fail("no local response") }
  inspect(r.status_code, content="403")
  inspect(@utf8.decode_lossy(r.body), content="{\"error\":\"no access\"}")
  inspect(emu.request_resumes(id), content="0")
}

///|
test "timeout fails closed, or open when configured" {
  let emu = setup()
  let id = request(emu)
  emu.call_on_http_call_response(emu.http_calls()[0].token, [], b"")
  guard emu.local_response(id) is Some(r) else { fail("no local response") }
  inspect(r.status_code, content="503")
  let open = setup(cfg="{\"cluster\":\"authz\",\"fail_open\":true}")
  let id2 = request(open)
  open.call_on_http_call_response(open.http_calls()[0].token, [], b"")
  inspect(open.request_resumes(id2), content="1")
  debug_inspect(open.metric("ext_authz.failed"), content="Some(1)")
}

///|
test "configuration without a cluster is rejected" {
  let emu = @proxytest.HostEmulator::new(plugin_config=b"{\"path\":\"/x\"}")
  inspect(emu.start(), content="false")
}

///|
test "fail open never forwards a forged identity" {
  let emu = setup(
    cfg="{\"cluster\":\"authz\",\"fail_open\":true,\"copy_back\":[\"x-user-id\"]}",
  )
  let id = request(emu)
  emu.call_on_http_call_response(emu.http_calls()[0].token, [], b"")
  inspect(emu.request_resumes(id), content="1")
  debug_inspect(
    emu.request_headers(id).filter(fn(kv) { kv.0 == "x-user-id" }),
    content="[]",
  )
}

///|
test "the request body waits for the verdict" {
  let emu = setup()
  let id = request(emu)
  let a = emu.call_on_request_body(id, b"{\"amount\":100}")
  inspect(a, content="Pause")
  inspect(emu.forwarded_request_body(id).length(), content="0")
  emu.call_on_http_call_response(
    emu.http_calls()[0].token,
    [(":status", "403")],
    b"",
  )
  // Denied: the body never reaches the upstream.
  inspect(emu.forwarded_request_body(id).length(), content="0")
  let emu2 = setup()
  let id2 = request(emu2)
  let _ = emu2.call_on_request_body(id2, b"{\"amount\":100}")
  emu2.call_on_http_call_response(
    emu2.http_calls()[0].token,
    [(":status", "200")],
    b"",
  )
  inspect(
    @utf8.decode_lossy(emu2.forwarded_request_body(id2)),
    content="{\"amount\":100}",
  )
}

///|
test "a duplicated forwarded header is rejected before any callout" {
  let emu = setup()
  let id = emu.init_http()
  let a = emu.call_on_request_headers(id, [
    (":method", "GET"),
    (":path", "/"),
    ("authorization", "Bearer good"),
    ("authorization", "Bearer evil"),
  ])
  inspect(a, content="Pause")
  inspect(emu.http_calls().length(), content="0")
  guard emu.local_response(id) is Some(r) else { fail("expected a 400") }
  inspect(r.status_code, content="400")
  inspect(r.details, content="ext_authz_duplicate_header")
}
