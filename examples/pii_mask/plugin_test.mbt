///|
fn run(
  headers : Array[(String, String)],
  chunks : Array[Bytes],
) -> (@proxytest.HostEmulator, Int32) {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start()) catch {
    _ => abort("start")
  }
  let id = emu.init_http()
  let _ = emu.call_on_response_headers(id, headers)
  for i, c in chunks {
    let _ = emu.call_on_response_body(
      id,
      c,
      end_of_stream=i == chunks.length() - 1,
    )
  }
  (emu, id)
}

///|
test "a phone number split across chunks is still masked" {
  let (emu, id) = run([("content-type", "application/json")], [
    b"{\"tel\":\"138123", b"45678\"}",
  ])
  inspect(
    @utf8.decode_lossy(emu.response_body(id)),
    content="{\"tel\":\"138****5678\"}",
  )
  debug_inspect(emu.metric("pii_mask.masked_responses"), content="Some(1)")
}

///|
test "binary and compressed responses are untouched" {
  let (emu, id) = run([("content-type", "image/png")], [b"13812345678"])
  inspect(emu.response_body(id), content="b\"13812345678\"")
  let (emu2, id2) = run(
    [("content-type", "text/plain"), ("content-encoding", "gzip")],
    [b"13812345678"],
  )
  inspect(emu2.response_body(id2), content="b\"13812345678\"")
  debug_inspect(emu2.metric("pii_mask.skipped_encoded"), content="Some(1)")
}

///|
test "a body that ends with trailers is masked before it leaves" {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start())
  let id = emu.init_http()
  let _ = emu.call_on_response_headers(id, [
    ("content-type", "application/json"),
  ])
  let a = emu.call_on_response_body(
    id,
    b"{\"tel\":\"13812345678\"}",
    end_of_stream=false,
  )
  debug_inspect(a, content="Pause")
  inspect(emu.forwarded_response_body(id).length(), content="0")
  let _ = emu.call_on_response_trailers(id, [("x-checksum", "1")])
  inspect(
    @utf8.decode_lossy(emu.forwarded_response_body(id)),
    content="{\"tel\":\"138****5678\"}",
  )
}

///|
test "grpc responses are not treated as text" {
  let (emu, id) = run([("content-type", "application/grpc+json")], [
    b"13812345678",
  ])
  inspect(emu.response_body(id), content="b\"13812345678\"")
}

///|
test "accept-encoding and range are stripped so the upstream sends the whole body in plain text" {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start()) catch {
    _ => abort("start")
  }
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [
    (":path", "/"),
    ("accept-encoding", "gzip, br"),
    ("range", "bytes=0-9"),
    ("if-range", "\"v1\""),
  ])
  debug_inspect(emu.request_headers(id), content="[(\":path\", \"/\")]")
}

///|
test "invalid UTF-8 around PII keeps every byte and the length" {
  let body = b"\xff\xfe tel 13812345678 \xc3"
  let (emu, id) = run([("content-type", "text/plain")], [body])
  let out = emu.response_body(id)
  inspect(out.length() == body.length(), content="true")
  inspect(out, content="b\"\\xff\\xfe tel 138****5678 \\xc3\"")
}

///|
test "a body without content-type is still masked" {
  let (emu, id) = run([], [b"{\"tel\":\"13812345678\"}"])
  inspect(
    @utf8.decode_lossy(emu.response_body(id)),
    content="{\"tel\":\"138****5678\"}",
  )
}

///|
test "server-sent events stream event by event, masked" {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start())
  let id = emu.init_http()
  let _ = emu.call_on_response_headers(id, [
    ("content-type", "text/event-stream"),
  ])
  // A complete event goes out at once.
  let a = emu.call_on_response_body(
    id,
    b"data: call 13812345678\n\n",
    end_of_stream=false,
  )
  debug_inspect(a, content="Continue")
  inspect(
    @utf8.decode_lossy(emu.forwarded_response_body(id)),
    content="data: call 138****5678\n\n",
  )
  // A number split across chunks inside one event is held until the event
  // is complete.
  let b = emu.call_on_response_body(id, b"data: 139123", end_of_stream=false)
  debug_inspect(b, content="Pause")
  let c = emu.call_on_response_body(id, b"45678\r\n\r\n", end_of_stream=false)
  debug_inspect(c, content="Continue")
  let _ = emu.call_on_response_body(id, b"data: end", end_of_stream=true)
  inspect(
    @utf8.decode_lossy(emu.forwarded_response_body(id)),
    content="data: call 138****5678\n\ndata: 139****5678\r\n\r\ndata: end",
  )
}
