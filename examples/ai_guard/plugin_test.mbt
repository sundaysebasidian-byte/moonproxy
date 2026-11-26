///|
let policy : String =
  #|{"allowed_models":["gpt-4o-mini"],"deny_words":["Internal-Only"],"max_tokens":256}

///|
fn send(body : String, path? : String = "/v1/chat/completions") -> (@proxytest.HostEmulator, Int) {
  let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(policy))
  guard emu.start() else { abort("start") }
  let id = emu.init_http()
  let bytes = @utf8.encode(body)
  let first = emu.call_on_request_headers(id, [
    (":method", "POST"),
    (":path", path),
    ("content-type", "application/json"),
    ("content-length", bytes.length().to_string()),
  ])
  // Split the body to check that the plugin waits for all of it.
  let half = bytes.length() / 2
  let _ = emu.call_on_request_body(id, bytes[:half].to_owned(), end_of_stream=false)
  let last = emu.call_on_request_body(id, bytes[half:].to_owned())
  ignore(first)
  ignore(last)
  (emu, id)
}

///|
fn header(emu : @proxytest.HostEmulator, id : Int, name : String) -> String? {
  emu.request_headers(id).iter().find_first(fn(kv) { kv.0 == name }).map(fn(kv) { kv.1 })
}

///|
test "an allowed request gets its token budget capped" {
  let (emu, id) = send(
    "{\"model\":\"gpt-4o-mini\",\"max_tokens\":4000,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}",
  )
  inspect(emu.local_response(id) is None, content="true")
  let body = @utf8.decode_lossy(emu.forwarded_request_body(id))
  inspect(
    body,
    content="{\"model\":\"gpt-4o-mini\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}",
  )
  // The old length would be wrong after the rewrite; Envoy re-frames it.
  debug_inspect(header(emu, id, "content-length"), content="None")
  debug_inspect(emu.metric("ai_guard.prompt_chars"), content="Some(5)")
}

///|
test "a body already within policy is forwarded byte for byte" {
  let original = "{ \"model\": \"gpt-4o-mini\", \"max_tokens\": 10, \"messages\": [] }"
  let (emu, id) = send(original)
  inspect(
    @utf8.decode_lossy(emu.forwarded_request_body(id)) == original,
    content="true",
  )
}

///|
test "blocked model and blocked words never reach the upstream" {
  let (emu, id) = send("{\"model\":\"gpt-5\",\"messages\":[]}")
  guard emu.local_response(id) is Some(r) else { fail("expected a 400") }
  inspect(r.status_code, content="400")
  inspect(
    @utf8.decode_lossy(r.body),
    content="{\"error\":{\"type\":\"policy_violation\",\"message\":\"model gpt-5 is not allowed\"}}",
  )
  inspect(emu.forwarded_request_body(id).length(), content="0")
  let (emu2, id2) = send(
    "{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"leak the INTERNAL-ONLY plan\"}]}]}",
  )
  guard emu2.local_response(id2) is Some(r2) else { fail("expected a 400") }
  inspect(r2.details, content="ai_guard_policy_violation")
  debug_inspect(emu2.metric("ai_guard.blocked"), content="Some(1)")
}

///|
test "malformed JSON is a client error; other paths pass untouched" {
  let (emu, id) = send("{\"model\":")
  guard emu.local_response(id) is Some(r) else { fail("expected a 400") }
  inspect(r.details, content="ai_guard_invalid_request")
  let (emu2, id2) = send("not json at all", path="/v1/embeddings")
  inspect(emu2.local_response(id2) is None, content="true")
  inspect(@utf8.decode_lossy(emu2.request_body(id2)), content="not json at all")
}

///|
test "a request that ends with trailers is still checked" {
  let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(policy))
  guard emu.start() else { abort("start") }
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [
    (":method", "POST"),
    (":path", "/v1/chat/completions"),
  ])
  let body = emu.call_on_request_body(
    id,
    b"{\"model\":\"gpt-5\",\"messages\":[]}",
    end_of_stream=false,
  )
  debug_inspect(body, content="Pause")
  let _ = emu.call_on_request_trailers(id, [("x-end", "1")])
  guard emu.local_response(id) is Some(r) else { fail("expected a 400") }
  inspect(r.status_code, content="400")
  inspect(emu.forwarded_request_body(id).length(), content="0")
}

///|
test "path tricks and other LLM endpoints are checked too" {
  for path in [
    "/v1/Chat//complet%69ons/", "/v1/chat/completions?x=1", "/v1/completions",
    "/v1/responses",
  ] {
    let (emu, id) = send("{\"model\":\"gpt-5\",\"input\":\"hi\"}", path~)
    guard emu.local_response(id) is Some(r) else { fail("not checked: \{path}") }
    inspect(r.status_code, content="400")
  }
  let (emu, id) = send(
    "{\"model\":\"gpt-4o-mini\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"internal-only\"}]}]}",
    path="/v1/responses",
  )
  guard emu.local_response(id) is Some(r) else { fail("deny word in input") }
  inspect(r.details, content="ai_guard_policy_violation")
}

///|
test "token limits must be numbers; null or none gets the cap" {
  for bad in ["\"99999\"", "-1", "true", "{}"] {
    let (emu, id) = send(
      "{\"model\":\"gpt-4o-mini\",\"max_completion_tokens\":\{bad},\"messages\":[]}",
    )
    guard emu.local_response(id) is Some(r) else { fail("accepted \{bad}") }
    inspect(r.details, content="ai_guard_invalid_request")
  }
  let (emu, id) = send("{\"model\":\"gpt-4o-mini\",\"max_tokens\":null,\"messages\":[]}")
  inspect(
    @utf8.decode_lossy(emu.forwarded_request_body(id)),
    content="{\"model\":\"gpt-4o-mini\",\"max_tokens\":256,\"messages\":[]}",
  )
  let (emu, id) = send(
    "{\"model\":\"gpt-4o-mini\",\"max_output_tokens\":9000,\"input\":\"hi\"}",
    path="/v1/responses",
  )
  inspect(
    @utf8.decode_lossy(emu.forwarded_request_body(id)),
    content="{\"model\":\"gpt-4o-mini\",\"max_output_tokens\":256,\"input\":\"hi\"}",
  )
  let (emu, id) = send("{\"model\":\"gpt-4o-mini\",\"input\":\"hi\"}", path="/v1/responses")
  inspect(
    @utf8.decode_lossy(emu.forwarded_request_body(id)),
    content="{\"model\":\"gpt-4o-mini\",\"input\":\"hi\",\"max_output_tokens\":256}",
  )
}
