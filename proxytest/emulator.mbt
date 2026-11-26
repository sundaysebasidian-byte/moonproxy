///|
/// An in-process proxy-wasm host for unit tests, modelled on Envoy's
/// behaviour (see `docs/emulator.md` for the rules it reproduces):
///
/// - header names are lower-cased; `get_header` returns the first value;
/// - request/response headers are writable only inside their callback or
///   while that direction is paused, and read-only in the log phase;
/// - body buffers follow Envoy `Buffer::copyFrom` (start 0 drains+prepends,
///   start >= length appends, anything else is `BadArgument`);
/// - a paused body accumulates the following chunks, like
///   `StopIterationAndBuffer`;
/// - `Pause` from a headers callback stops the whole direction
///   (`StopAllIterationAndWatermark`, what proxy-wasm-cpp-host turns it
///   into): later body chunks and trailers are held back, not shown to the
///   plugin, and replayed after the plugin resumes the stream;
/// - shared data uses a global CAS counter, exactly like proxy-wasm-cpp-host.
struct HostEmulator {
  vm_config : Bytes
  plugin_config : Bytes
  root_id : Int32
  mut next_id : Int32
  mut active : Int32
  streams : Map[Int32, Stream]
  logs : Array[(@moonproxy.LogLevel, String)]
  mut log_level : @moonproxy.LogLevel
  mut now_nanos : Int64
  mut tick_ms : Int32
  shared : Map[String, (Bytes, Int32)]
  mut cas_counter : Int32
  queue_ids : Map[String, Int32]
  queues : Map[Int32, Array[Bytes]]
  ready_queues : Array[Int32]
  properties : Map[String, Bytes]
  metric_ids : Map[String, Int32]
  metrics : Array[MetricSlot]
  calls : Map[Int32, HttpCall]
  mut next_token : Int32
  mut callout_response : (
    Array[(String, String)],
    Bytes,
    Array[(String, String)],
  )?
  mut done_called : Bool
  /// Inside `on_configure`: the only time Envoy serves the plugin config.
  mut configuring : Bool
  clusters : Array[String]
  mut cas_failures : Int32
}

///|
priv struct MetricSlot {
  kind : @moonproxy.MetricType
  mut value : Int64
}

///|
priv enum Access {
  Closed
  Writable
  ReadOnly
}

///|
priv struct Stream {
  is_http : Bool
  maps : Map[@moonproxy.MapType, Array[(String, String)]]
  mut req_headers : Access
  mut resp_headers : Access
  mut req_trailers : Access
  mut resp_trailers : Access
  buffers : Map[@moonproxy.BufferType, Bytes]
  forwarded : Map[@moonproxy.BufferType, Bytes]
  paused : Map[@moonproxy.BufferType, Bool]
  mut request_paused : Bool
  mut response_paused : Bool
  mut request_resumes : Int32
  mut response_resumes : Int32
  mut local_response : LocalResponse?
  /// Sent but not yet run through the plugin's response callbacks.
  mut local_pending : Bool
  mut reset : Bool
  mut closed_downstream : Bool
  mut closed_upstream : Bool
  /// Headers callback returned Pause: the direction is stopped entirely.
  mut req_stop_all : Bool
  mut resp_stop_all : Bool
  held_req : Array[Held]
  held_resp : Array[Held]
  /// Resumed while stopped: replay what was held once the callback returns.
  mut replay_req : Bool
  mut replay_resp : Bool
}

///|
priv enum Held {
  Data(Bytes, Bool)
  Trailers(Array[(String, String)])
}

///|
/// A response sent with `send_http_response` instead of the upstream.
#derive(Debug, Eq)
pub struct LocalResponse {
  status_code : Int32
  headers : Array[(String, String)]
  body : Bytes
  details : String
}

///|
/// An outgoing HTTP callout waiting for `call_on_http_call_response`.
#derive(Debug, Eq)
pub struct HttpCall {
  token : Int32
  upstream : String
  headers : Array[(String, String)]
  body : Bytes
  trailers : Array[(String, String)]
  timeout_ms : Int32
}

///|
/// Create an emulator, install it as the SDK host and create the root
/// context (id 1). Call `start` next.
///
/// `clusters` lists the upstream clusters that exist; when it is not empty,
/// `dispatch_http_call` to any other name fails with `BadArgument`, as in
/// Envoy. Empty means every name is accepted.
pub fn HostEmulator::new(
  plugin_config~ : Bytes = b"",
  vm_config~ : Bytes = b"",
  clusters~ : Array[String] = [],
) -> HostEmulator {
  let emu : HostEmulator = {
    vm_config,
    plugin_config,
    root_id: 1,
    next_id: 2,
    active: 0,
    streams: Map([]),
    logs: [],
    log_level: Trace,
    now_nanos: 1_700_000_000_000_000_000L,
    tick_ms: 0,
    shared: Map([]),
    cas_counter: 0,
    queue_ids: Map([]),
    queues: Map([]),
    ready_queues: [],
    properties: Map([]),
    metric_ids: Map([]),
    metrics: [],
    calls: Map([]),
    next_token: 1,
    callout_response: None,
    done_called: false,
    configuring: false,
    clusters,
    cas_failures: 0,
  }
  @moonproxy.reset_contexts()
  @moonproxy.set_host(emu)
  emu.active = emu.root_id
  @moonproxy.abi_on_context_create(emu.root_id, 0)
  emu
}

///|
/// Run `on_vm_start` and `on_plugin_start`; `false` if either rejects.
pub fn HostEmulator::start(self : HostEmulator) -> Bool {
  self.active = self.root_id
  let vm = @moonproxy.abi_on_vm_start(self.root_id, self.vm_config.length())
  self.active = self.root_id
  self.configuring = true
  let cfg = @moonproxy.abi_on_configure(
    self.root_id,
    self.plugin_config.length(),
  )
  self.configuring = false
  vm != 0 && cfg != 0
}

///|
fn new_stream(is_http : Bool) -> Stream {
  {
    is_http,
    maps: Map([]),
    req_headers: Closed,
    resp_headers: Closed,
    req_trailers: Closed,
    resp_trailers: Closed,
    buffers: Map([]),
    forwarded: Map([]),
    paused: Map([]),
    request_paused: false,
    response_paused: false,
    request_resumes: 0,
    response_resumes: 0,
    local_response: None,
    local_pending: false,
    reset: false,
    closed_downstream: false,
    closed_upstream: false,
    req_stop_all: false,
    resp_stop_all: false,
    held_req: [],
    held_resp: [],
    replay_req: false,
    replay_resp: false,
  }
}

///|
fn HostEmulator::create(self : HostEmulator, is_http : Bool) -> Int32 {
  let id = self.next_id
  self.next_id += 1
  self.streams[id] = new_stream(is_http)
  self.active = id
  @moonproxy.abi_on_context_create(id, self.root_id)
  id
}

///|
/// Start a new HTTP stream and return its context id.
pub fn HostEmulator::init_http(self : HostEmulator) -> Int32 {
  self.create(true)
}

///|
/// Start a new TCP connection and return its context id.
pub fn HostEmulator::init_tcp(self : HostEmulator) -> Int32 {
  self.create(false)
}

///|
fn HostEmulator::stream(self : HostEmulator, id : Int32) -> Stream {
  match self.streams.get(id) {
    Some(s) => s
    None => abort("proxytest: unknown stream \{id}")
  }
}

///|
fn lower_pairs(pairs : Array[(String, String)]) -> Array[(String, String)] {
  pairs.map(fn(p) { (p.0.to_lower(), p.1) })
}

///|
fn to_action(code : Int32) -> @moonproxy.Action {
  if code == 0 {
    Continue
  } else {
    Pause
  }
}

///|
fn b2i(b : Bool) -> Int32 {
  if b {
    1
  } else {
    0
  }
}

// ---- HTTP driving -------------------------------------------------------

///|
pub fn HostEmulator::call_on_request_headers(
  self : HostEmulator,
  id : Int32,
  headers : Array[(String, String)],
  end_of_stream~ : Bool = false,
) -> @moonproxy.Action {
  let s = self.stream(id)
  s.maps[HttpRequestHeaders] = lower_pairs(headers)
  s.req_headers = Writable
  self.active = id
  let a = to_action(
    @moonproxy.abi_on_request_headers(id, headers.length(), b2i(end_of_stream)),
  )
  s.request_paused = a == Pause
  s.req_stop_all = a == Pause && !s.replay_req
  if a == Continue {
    s.req_headers = Closed
  }
  self.settle()
  a
}

///|
/// Work Envoy does after a plugin callback returns: send local responses,
/// then hand data held back by a stopped direction to the plugin (as one
/// buffered chunk, followed by the trailers), as `continueDecoding` /
/// `continueEncoding` does.
fn HostEmulator::settle(self : HostEmulator) -> Unit {
  self.deliver_local_responses()
  let ids = self.streams.keys().collect()
  for id in ids {
    guard self.streams.get(id) is Some(s) else { continue }
    if s.replay_req {
      s.replay_req = false
      let held = s.held_req.copy()
      s.held_req.clear()
      if s.local_response is None {
        self.replay(id, held, false)
      }
    }
    guard self.streams.get(id) is Some(s) else { continue }
    if s.replay_resp {
      s.replay_resp = false
      let held = s.held_resp.copy()
      s.held_resp.clear()
      self.replay(id, held, true)
    }
  }
}

///|
fn HostEmulator::replay(
  self : HostEmulator,
  id : Int32,
  held : Array[Held],
  response : Bool,
) -> Unit {
  let data = Buffer()
  let mut eos = false
  let mut has_data = false
  let mut trailers = None
  for h in held {
    match h {
      Data(b, e) => {
        data.write_bytes(b)
        eos = e
        has_data = true
      }
      Trailers(t) => trailers = Some(t)
    }
  }
  if has_data {
    let _ = if response {
      self.call_on_response_body(id, data.to_bytes(), end_of_stream=eos)
    } else {
      self.call_on_request_body(id, data.to_bytes(), end_of_stream=eos)
    }
  }
  if trailers is Some(t) {
    let _ = if response {
      self.call_on_response_trailers(id, t)
    } else {
      self.call_on_request_trailers(id, t)
    }
  }
}

///|
/// Envoy sends a local response after the plugin callback returns
/// (`addAfterVmCallAction`), and it travels through the filter chain like
/// any response: the plugin's own `on_response_headers` and
/// `on_response_body` see it, and what they change is what the client gets.
fn HostEmulator::deliver_local_responses(self : HostEmulator) -> Unit {
  for id, s in self.streams {
    guard s.local_pending && s.local_response is Some(r) else { continue }
    s.local_pending = false
    s.request_paused = false
    s.req_headers = Closed
    s.req_trailers = Closed
    let headers = [(":status", r.status_code.to_string())]
    headers.append(r.headers)
    if r.body.length() > 0 {
      headers.push(("content-length", r.body.length().to_string()))
    }
    s.maps[HttpResponseHeaders] = headers
    s.resp_headers = Writable
    s.buffers[HttpResponseBody] = b""
    s.forwarded[HttpResponseBody] = b""
    self.active = id
    let _ = @moonproxy.abi_on_response_headers(
      id,
      headers.length(),
      b2i(r.body.length() == 0),
    )
    if r.body.length() > 0 {
      s.buffers[HttpResponseBody] = r.body
      self.active = id
      let _ = @moonproxy.abi_on_response_body(id, r.body.length(), 1)
    }
    s.resp_headers = Closed
    // A local response ends the stream whatever the plugin returns.
    let final_body = concat(
      s.forwarded.get(HttpResponseBody).unwrap_or(b""),
      s.buffers.get(HttpResponseBody).unwrap_or(b""),
    )
    s.forwarded[HttpResponseBody] = final_body
    s.buffers[HttpResponseBody] = b""
    let final_headers = s.maps
      .get(HttpResponseHeaders)
      .unwrap_or([])
      .filter(fn(kv) { kv.0 != ":status" && kv.0 != "content-length" })
    s.local_response = Some({ ..r, headers: final_headers, body: final_body, })
  }
}

///|
fn HostEmulator::body(
  self : HostEmulator,
  id : Int32,
  kind : @moonproxy.BufferType,
  chunk : Bytes,
  eos : Bool,
  call : (Int32, Int32, Int32) -> Int32,
) -> @moonproxy.Action {
  let s = self.stream(id)
  let prev = if s.paused.get(kind).unwrap_or(false) {
    s.buffers.get(kind).unwrap_or(b"")
  } else {
    b""
  }
  let buf = concat(prev, chunk)
  s.buffers[kind] = buf
  self.active = id
  let a = to_action(call(id, buf.length(), b2i(eos)))
  if a == Continue {
    self.flush(s, kind)
  } else {
    s.paused[kind] = true
  }
  a
}

///|
fn HostEmulator::flush(
  _self : HostEmulator,
  s : Stream,
  kind : @moonproxy.BufferType,
) -> Unit {
  let sent = s.forwarded.get(kind).unwrap_or(b"")
  s.forwarded[kind] = concat(sent, s.buffers.get(kind).unwrap_or(b""))
  s.buffers[kind] = b""
  s.paused[kind] = false
}

///|
fn concat(a : Bytes, b : Bytes) -> Bytes {
  if a.length() == 0 {
    return b
  }
  if b.length() == 0 {
    return a
  }
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
pub fn HostEmulator::call_on_request_body(
  self : HostEmulator,
  id : Int32,
  chunk : Bytes,
  end_of_stream~ : Bool = true,
) -> @moonproxy.Action {
  let s = self.stream(id)
  if s.req_stop_all {
    s.held_req.push(Data(chunk, end_of_stream))
    return Pause
  }
  let a = self.body(id, HttpRequestBody, chunk, end_of_stream, fn(i, n, e) {
    @moonproxy.abi_on_request_body(i, n, e)
  })
  let s = self.stream(id)
  s.request_paused = a == Pause
  // Headers held back by an earlier Pause leave together with this data,
  // after which Envoy no longer lets the plugin touch them.
  if a == Continue {
    s.req_headers = Closed
  }
  self.settle()
  a
}

///|
pub fn HostEmulator::call_on_request_trailers(
  self : HostEmulator,
  id : Int32,
  trailers : Array[(String, String)],
) -> @moonproxy.Action {
  let s = self.stream(id)
  if s.req_stop_all {
    s.held_req.push(Trailers(trailers))
    return Pause
  }
  s.maps[HttpRequestTrailers] = lower_pairs(trailers)
  s.req_trailers = Writable
  self.active = id
  let a = to_action(@moonproxy.abi_on_request_trailers(id, trailers.length()))
  if a == Continue {
    // Continuing at the trailers releases everything still held back:
    // paused headers and buffered body leave with them.
    s.req_trailers = Closed
    s.req_headers = Closed
    s.request_paused = false
    self.flush(s, HttpRequestBody)
  }
  self.settle()
  a
}

///|
pub fn HostEmulator::call_on_response_headers(
  self : HostEmulator,
  id : Int32,
  headers : Array[(String, String)],
  end_of_stream~ : Bool = false,
) -> @moonproxy.Action {
  let s = self.stream(id)
  s.maps[HttpResponseHeaders] = lower_pairs(headers)
  s.resp_headers = Writable
  self.active = id
  let a = to_action(
    @moonproxy.abi_on_response_headers(id, headers.length(), b2i(end_of_stream)),
  )
  s.response_paused = a == Pause
  s.resp_stop_all = a == Pause && !s.replay_resp
  if a == Continue {
    s.resp_headers = Closed
  }
  // A local response sent this late is not replayed through the filter.
  self.stream(id).local_pending = false
  self.settle()
  a
}

///|
pub fn HostEmulator::call_on_response_body(
  self : HostEmulator,
  id : Int32,
  chunk : Bytes,
  end_of_stream~ : Bool = true,
) -> @moonproxy.Action {
  let s = self.stream(id)
  if s.resp_stop_all {
    s.held_resp.push(Data(chunk, end_of_stream))
    return Pause
  }
  let a = self.body(id, HttpResponseBody, chunk, end_of_stream, fn(i, n, e) {
    @moonproxy.abi_on_response_body(i, n, e)
  })
  let s = self.stream(id)
  s.response_paused = a == Pause
  // Headers held back by an earlier Pause leave together with this data,
  // after which Envoy no longer lets the plugin touch them.
  if a == Continue {
    s.resp_headers = Closed
  }
  // A local response sent this late is not replayed through the filter.
  self.stream(id).local_pending = false
  self.settle()
  a
}

///|
pub fn HostEmulator::call_on_response_trailers(
  self : HostEmulator,
  id : Int32,
  trailers : Array[(String, String)],
) -> @moonproxy.Action {
  let s = self.stream(id)
  if s.resp_stop_all {
    s.held_resp.push(Trailers(trailers))
    return Pause
  }
  s.maps[HttpResponseTrailers] = lower_pairs(trailers)
  s.resp_trailers = Writable
  self.active = id
  let a = to_action(@moonproxy.abi_on_response_trailers(id, trailers.length()))
  if a == Continue {
    // Continuing at the trailers releases everything still held back:
    // paused headers and buffered body leave with them.
    s.resp_trailers = Closed
    s.resp_headers = Closed
    s.response_paused = false
    self.flush(s, HttpResponseBody)
  }
  // A local response sent this late is not replayed through the filter.
  self.stream(id).local_pending = false
  self.settle()
  a
}

///|
/// Finish a stream the way Envoy does.
///
/// HTTP: the connection manager writes access logs before it destroys the
/// filters, so the order is `on_log` (headers and trailers readable, not
/// writable), then `on_done` and `on_delete` from `Context::onDestroy`, by
/// which time the header maps are gone. TCP (`Context::onCloseTCP`):
/// `on_done`, `on_log`, `on_delete`.
pub fn HostEmulator::complete_stream(self : HostEmulator, id : Int32) -> Unit {
  let s = self.stream(id)
  let set_maps = fn(a : Access) {
    s.req_headers = a
    s.resp_headers = a
    s.req_trailers = a
    s.resp_trailers = a
  }
  if s.is_http {
    set_maps(ReadOnly)
    self.active = id
    @moonproxy.abi_on_log(id)
    set_maps(Closed)
    self.active = id
    let _ = @moonproxy.abi_on_done(id)
  } else {
    self.active = id
    let _ = @moonproxy.abi_on_done(id)
    self.active = id
    @moonproxy.abi_on_log(id)
  }
  self.active = id
  @moonproxy.abi_on_delete(id)
  self.streams.remove(id)
}

// ---- TCP driving --------------------------------------------------------

///|
pub fn HostEmulator::call_on_new_connection(
  self : HostEmulator,
  id : Int32,
) -> @moonproxy.Action {
  self.active = id
  to_action(@moonproxy.abi_on_new_connection(id))
}

///|
pub fn HostEmulator::call_on_downstream_data(
  self : HostEmulator,
  id : Int32,
  data : Bytes,
  end_of_stream~ : Bool = false,
) -> @moonproxy.Action {
  self.body(id, DownstreamData, data, end_of_stream, fn(i, n, e) {
    @moonproxy.abi_on_downstream_data(i, n, e)
  })
}

///|
pub fn HostEmulator::call_on_upstream_data(
  self : HostEmulator,
  id : Int32,
  data : Bytes,
  end_of_stream~ : Bool = false,
) -> @moonproxy.Action {
  self.body(id, UpstreamData, data, end_of_stream, fn(i, n, e) {
    @moonproxy.abi_on_upstream_data(i, n, e)
  })
}

///|
pub fn HostEmulator::call_on_downstream_close(
  self : HostEmulator,
  id : Int32,
  peer~ : @moonproxy.PeerType = Remote,
) -> Unit {
  self.active = id
  @moonproxy.abi_on_downstream_connection_close(id, peer_to_int(peer))
}

///|
pub fn HostEmulator::call_on_upstream_close(
  self : HostEmulator,
  id : Int32,
  peer~ : @moonproxy.PeerType = Remote,
) -> Unit {
  self.active = id
  @moonproxy.abi_on_upstream_connection_close(id, peer_to_int(peer))
}

///|
fn peer_to_int(p : @moonproxy.PeerType) -> Int32 {
  match p {
    Unknown => 0
    Local => 1
    Remote => 2
  }
}

// ---- root-level driving -------------------------------------------------

///|
/// Fire one timer tick (only if the plugin set a tick period).
pub fn HostEmulator::tick(self : HostEmulator) -> Unit {
  if self.tick_ms > 0 {
    self.active = self.root_id
    @moonproxy.abi_on_tick(self.root_id)
  }
}

///|
/// Deliver pending `on_queue_ready` notifications.
pub fn HostEmulator::deliver_queue_ready(self : HostEmulator) -> Unit {
  let pending = self.ready_queues.copy()
  self.ready_queues.clear()
  for q in pending {
    self.active = self.root_id
    @moonproxy.abi_on_queue_ready(self.root_id, q)
  }
}

///|
/// Ask the plugin to shut down; returns what `on_plugin_done` answered.
pub fn HostEmulator::shutdown(self : HostEmulator) -> Bool {
  self.active = self.root_id
  @moonproxy.abi_on_done(self.root_id) != 0
}

///|
/// Make the next `n` compare-and-swap writes to shared data fail with
/// `CasMismatch`, as if another worker thread had written the key first.
pub fn HostEmulator::fail_next_cas(self : HostEmulator, n : Int32) -> Unit {
  self.cas_failures = n
}

///|
/// Deliver the response of a callout. `headers` empty means the call failed.
pub fn HostEmulator::call_on_http_call_response(
  self : HostEmulator,
  token : Int32,
  headers : Array[(String, String)],
  body : Bytes,
  trailers~ : Array[(String, String)] = [],
) -> Unit {
  guard self.calls.get(token) is Some(_) else {
    abort("proxytest: no pending callout \{token}")
  }
  self.calls.remove(token)
  self.callout_response = Some(
    (lower_pairs(headers), body, lower_pairs(trailers)),
  )
  self.active = self.root_id
  @moonproxy.abi_on_http_call_response(
    self.root_id,
    token,
    headers.length(),
    body.length(),
    trailers.length(),
  )
  self.callout_response = None
  self.settle()
}

// ---- inspection -----------------------------------------------------------

///|
pub fn HostEmulator::request_headers(
  self : HostEmulator,
  id : Int32,
) -> Array[(String, String)] {
  self.stream(id).maps.get(HttpRequestHeaders).unwrap_or([])
}

///|
pub fn HostEmulator::response_headers(
  self : HostEmulator,
  id : Int32,
) -> Array[(String, String)] {
  self.stream(id).maps.get(HttpResponseHeaders).unwrap_or([])
}

///|
fn HostEmulator::data(
  self : HostEmulator,
  id : Int32,
  kind : @moonproxy.BufferType,
) -> Bytes {
  let s = self.stream(id)
  concat(
    s.forwarded.get(kind).unwrap_or(b""),
    s.buffers.get(kind).unwrap_or(b""),
  )
}

///|
/// Request body forwarded so far plus whatever is still buffered.
pub fn HostEmulator::request_body(self : HostEmulator, id : Int32) -> Bytes {
  self.data(id, HttpRequestBody)
}

///|
/// Request body the upstream has actually been sent (data released by a
/// `Continue`); excludes anything still held by the plugin.
pub fn HostEmulator::forwarded_request_body(
  self : HostEmulator,
  id : Int32,
) -> Bytes {
  self.stream(id).forwarded.get(HttpRequestBody).unwrap_or(b"")
}

///|
/// Response body the client has actually been sent.
pub fn HostEmulator::forwarded_response_body(
  self : HostEmulator,
  id : Int32,
) -> Bytes {
  self.stream(id).forwarded.get(HttpResponseBody).unwrap_or(b"")
}

///|
pub fn HostEmulator::response_body(self : HostEmulator, id : Int32) -> Bytes {
  self.data(id, HttpResponseBody)
}

///|
pub fn HostEmulator::downstream_data(self : HostEmulator, id : Int32) -> Bytes {
  self.data(id, DownstreamData)
}

///|
pub fn HostEmulator::upstream_data(self : HostEmulator, id : Int32) -> Bytes {
  self.data(id, UpstreamData)
}

///|
pub fn HostEmulator::local_response(
  self : HostEmulator,
  id : Int32,
) -> LocalResponse? {
  self.stream(id).local_response
}

///|
/// How many times the plugin resumed the request with `resume_http_request`.
pub fn HostEmulator::request_resumes(self : HostEmulator, id : Int32) -> Int32 {
  self.stream(id).request_resumes
}

///|
pub fn HostEmulator::response_resumes(self : HostEmulator, id : Int32) -> Int32 {
  self.stream(id).response_resumes
}

///|
pub fn HostEmulator::is_request_paused(self : HostEmulator, id : Int32) -> Bool {
  self.stream(id).request_paused
}

///|
/// Make `log_level()` report `level` to the plugin.
pub fn HostEmulator::set_log_level(
  self : HostEmulator,
  level : @moonproxy.LogLevel,
) -> Unit {
  self.log_level = level
}

///|
pub fn HostEmulator::upstream_closed(self : HostEmulator, id : Int32) -> Bool {
  self.stream(id).closed_upstream
}

///|
/// Whether the plugin reset the HTTP stream (`reset_http_stream`).
pub fn HostEmulator::was_reset(self : HostEmulator, id : Int32) -> Bool {
  self.stream(id).reset
}

///|
pub fn HostEmulator::downstream_closed(self : HostEmulator, id : Int32) -> Bool {
  self.stream(id).closed_downstream
}

///|
/// Messages logged at `level` or above, oldest first.
pub fn HostEmulator::logs(
  self : HostEmulator,
  level~ : @moonproxy.LogLevel = Trace,
) -> Array[String] {
  self.logs.filter(fn(l) { l.0 >= level }).map(fn(l) { l.1 })
}

///|
/// Callouts sent and not yet answered, in token order.
pub fn HostEmulator::http_calls(self : HostEmulator) -> Array[HttpCall] {
  let out = self.calls.values().collect()
  out.sort_by_key(fn(c) { c.token })
  out
}

///|
/// Current value of a metric, by name.
pub fn HostEmulator::metric(self : HostEmulator, name : String) -> Int64? {
  self.metric_ids.get(name).map(fn(i) { self.metrics[i].value })
}

///|
pub fn HostEmulator::shared_data(self : HostEmulator, key : String) -> Bytes? {
  self.shared.get(key).map(fn(e) { e.0 })
}

///|
/// Preset a property returned by `get_property(path)`.
pub fn HostEmulator::set_property(
  self : HostEmulator,
  path : Array[String],
  value : Bytes,
) -> Unit {
  self.properties[path_key(@moonproxy.serialize_path(path))] = value
}

///|
pub fn HostEmulator::set_time_nanos(self : HostEmulator, t : Int64) -> Unit {
  self.now_nanos = t
}

///|
pub fn HostEmulator::tick_period_ms(self : HostEmulator) -> Int32 {
  self.tick_ms
}

///|
pub fn HostEmulator::done_called(self : HostEmulator) -> Bool {
  self.done_called
}

///|
fn path_key(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
pub extend LocalResponse with Debug::{to_repr}

///|
pub extend LocalResponse with Eq::{equal, not_equal}

///|
pub extend HttpCall with Debug::{to_repr}

///|
pub extend HttpCall with Eq::{equal, not_equal}
