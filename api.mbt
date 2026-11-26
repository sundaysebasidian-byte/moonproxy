///|
/// High-level plugin API. Every function acts on the context whose callback
/// is running (the "effective context" of the host).

///|
const MAX_SIZE : Int32 = 0x7fffffff

///|
fn check(op : String, st : Status) -> Unit raise HostError {
  if st != Ok {
    raise HostError(op, st)
  }
}

// ---- logging ------------------------------------------------------------

///|
pub fn log(level : LogLevel, msg : String) -> Unit {
  let _ = host().log(level, msg)
}

///|
pub fn log_trace(msg : String) -> Unit {
  log(Trace, msg)
}

///|
pub fn log_debug(msg : String) -> Unit {
  log(Debug, msg)
}

///|
pub fn log_info(msg : String) -> Unit {
  log(Info, msg)
}

///|
pub fn log_warn(msg : String) -> Unit {
  log(Warn, msg)
}

///|
pub fn log_error(msg : String) -> Unit {
  log(Error, msg)
}

///|
pub fn log_critical(msg : String) -> Unit {
  log(Critical, msg)
}

///|
/// The host's current log level; skip building expensive messages below it.
pub fn log_level() -> LogLevel {
  host().get_log_level()
}

// ---- time and timers ----------------------------------------------------

///|
/// Wall-clock time in nanoseconds since the Unix epoch.
pub fn current_time_nanos() -> Int64 {
  host().get_current_time_nanos()
}

///|
/// Call `RootContext::on_tick` every `ms` milliseconds (0 disables it).
pub fn set_tick_period_ms(ms : Int32) -> Unit raise HostError {
  check("set_tick_period_ms", host().set_tick_period_ms(ms))
}

// ---- configuration ------------------------------------------------------

///|
fn get_buffer_or_empty(
  op : String,
  kind : BufferType,
  start : Int32,
  size : Int32,
) -> Bytes raise HostError {
  let (st, data) = host().get_buffer(kind, start, size)
  match st {
    Ok => data
    NotFound | Empty => b""
    _ => raise HostError(op, st)
  }
}

///|
/// Raw bytes of the `vm_config.configuration` field.
pub fn get_vm_configuration() -> Bytes raise HostError {
  get_buffer_or_empty("get_vm_configuration", VmConfiguration, 0, MAX_SIZE)
}

///|
/// Raw bytes of the plugin `configuration` field (empty when none is set).
///
/// Envoy hands the plugin configuration out only while the plugin is being
/// configured or started; anywhere else this raises
/// `HostError(_, NotFound)` instead of quietly returning an empty
/// configuration. moonproxy serves it only in `on_plugin_start` (slightly
/// stricter than Envoy, which also serves it during `on_vm_start`), so that
/// plugins behave the same on every host. Parse it there and keep the
/// result.
pub fn get_plugin_configuration() -> Bytes raise HostError {
  if !configuring.val {
    raise HostError("get_plugin_configuration", NotFound)
  }
  get_buffer_or_empty(
    "get_plugin_configuration",
    PluginConfiguration,
    0,
    MAX_SIZE,
  )
}

// ---- buffers ------------------------------------------------------------

///|
/// Read `size` bytes starting at `start` from a buffer.
pub fn get_buffer(
  kind : BufferType,
  start~ : Int32 = 0,
  size~ : Int32 = MAX_SIZE,
) -> Bytes raise HostError {
  get_buffer_or_empty("get_buffer", kind, start, size)
}

///|
/// Overwrite a buffer region with the host's semantics: `start == 0`
/// drains `size` bytes and prepends `data`; `start >= length` appends.
pub fn set_buffer(
  kind : BufferType,
  start : Int32,
  size : Int32,
  data : Bytes,
) -> Unit raise HostError {
  check("set_buffer", host().set_buffer(kind, start, size, data))
}

///|
pub fn get_request_body() -> Bytes raise HostError {
  get_buffer(HttpRequestBody)
}

///|
/// Replace the whole buffered request body.
pub fn replace_request_body(body : Bytes) -> Unit raise HostError {
  set_buffer(HttpRequestBody, 0, MAX_SIZE, body)
}

///|
pub fn append_request_body(data : Bytes) -> Unit raise HostError {
  set_buffer(HttpRequestBody, MAX_SIZE, 0, data)
}

///|
pub fn prepend_request_body(data : Bytes) -> Unit raise HostError {
  set_buffer(HttpRequestBody, 0, 0, data)
}

///|
pub fn get_response_body() -> Bytes raise HostError {
  get_buffer(HttpResponseBody)
}

///|
/// Replace the whole buffered response body.
pub fn replace_response_body(body : Bytes) -> Unit raise HostError {
  set_buffer(HttpResponseBody, 0, MAX_SIZE, body)
}

///|
pub fn append_response_body(data : Bytes) -> Unit raise HostError {
  set_buffer(HttpResponseBody, MAX_SIZE, 0, data)
}

///|
pub fn prepend_response_body(data : Bytes) -> Unit raise HostError {
  set_buffer(HttpResponseBody, 0, 0, data)
}

///|
pub fn get_downstream_data() -> Bytes raise HostError {
  get_buffer(DownstreamData)
}

///|
pub fn replace_downstream_data(data : Bytes) -> Unit raise HostError {
  set_buffer(DownstreamData, 0, MAX_SIZE, data)
}

///|
pub fn get_upstream_data() -> Bytes raise HostError {
  get_buffer(UpstreamData)
}

///|
pub fn replace_upstream_data(data : Bytes) -> Unit raise HostError {
  set_buffer(UpstreamData, 0, MAX_SIZE, data)
}

// ---- header maps --------------------------------------------------------

///|
/// All pairs of a header map, in host order (duplicates preserved).
pub fn get_header_map(
  kind : MapType,
) -> Array[(String, String)] raise HostError {
  let (st, data) = host().get_map_pairs(kind)
  match st {
    Ok => deserialize_map(data)
    NotFound => []
    _ => raise HostError("get_header_map", st)
  }
}

///|
/// Replace a whole header map.
pub fn set_header_map(
  kind : MapType,
  pairs : Array[(String, String)],
) -> Unit raise HostError {
  check("set_header_map", host().set_map_pairs(kind, serialize_map(pairs)))
}

///|
/// Value of one header (`None` if absent). Envoy returns only the first
/// value of a repeated header; use `get_header_map` to see all of them.
pub fn get_header(kind : MapType, name : String) -> String? raise HostError {
  let (st, data) = host().get_map_value(kind, name)
  match st {
    Ok => Some(@utf8.decode_lossy(data))
    NotFound => None
    _ => raise HostError("get_header", st)
  }
}

///|
/// Set a header, replacing any existing values.
pub fn replace_header(
  kind : MapType,
  name : String,
  value : String,
) -> Unit raise HostError {
  check("replace_header", host().replace_map_value(kind, name, value))
}

///|
/// Add a header value, keeping existing ones.
pub fn add_header(
  kind : MapType,
  name : String,
  value : String,
) -> Unit raise HostError {
  check("add_header", host().add_map_value(kind, name, value))
}

///|
pub fn remove_header(kind : MapType, name : String) -> Unit raise HostError {
  check("remove_header", host().remove_map_value(kind, name))
}

///|
pub fn get_request_headers() -> Array[(String, String)] raise HostError {
  get_header_map(HttpRequestHeaders)
}

///|
pub fn set_request_headers(
  pairs : Array[(String, String)],
) -> Unit raise HostError {
  set_header_map(HttpRequestHeaders, pairs)
}

///|
pub fn get_request_header(name : String) -> String? raise HostError {
  get_header(HttpRequestHeaders, name)
}

///|
pub fn replace_request_header(
  name : String,
  value : String,
) -> Unit raise HostError {
  replace_header(HttpRequestHeaders, name, value)
}

///|
pub fn add_request_header(
  name : String,
  value : String,
) -> Unit raise HostError {
  add_header(HttpRequestHeaders, name, value)
}

///|
pub fn remove_request_header(name : String) -> Unit raise HostError {
  remove_header(HttpRequestHeaders, name)
}

///|
pub fn get_response_headers() -> Array[(String, String)] raise HostError {
  get_header_map(HttpResponseHeaders)
}

///|
pub fn set_response_headers(
  pairs : Array[(String, String)],
) -> Unit raise HostError {
  set_header_map(HttpResponseHeaders, pairs)
}

///|
pub fn get_response_header(name : String) -> String? raise HostError {
  get_header(HttpResponseHeaders, name)
}

///|
pub fn replace_response_header(
  name : String,
  value : String,
) -> Unit raise HostError {
  replace_header(HttpResponseHeaders, name, value)
}

///|
pub fn add_response_header(
  name : String,
  value : String,
) -> Unit raise HostError {
  add_header(HttpResponseHeaders, name, value)
}

///|
pub fn remove_response_header(name : String) -> Unit raise HostError {
  remove_header(HttpResponseHeaders, name)
}

///|
pub fn get_request_trailers() -> Array[(String, String)] raise HostError {
  get_header_map(HttpRequestTrailers)
}

///|
pub fn get_response_trailers() -> Array[(String, String)] raise HostError {
  get_header_map(HttpResponseTrailers)
}

///|
pub fn set_request_trailers(
  pairs : Array[(String, String)],
) -> Unit raise HostError {
  set_header_map(HttpRequestTrailers, pairs)
}

///|
pub fn set_response_trailers(
  pairs : Array[(String, String)],
) -> Unit raise HostError {
  set_header_map(HttpResponseTrailers, pairs)
}

///|
pub fn replace_request_trailer(
  name : String,
  value : String,
) -> Unit raise HostError {
  replace_header(HttpRequestTrailers, name, value)
}

///|
pub fn replace_response_trailer(
  name : String,
  value : String,
) -> Unit raise HostError {
  replace_header(HttpResponseTrailers, name, value)
}

// ---- stream control -----------------------------------------------------

///|
/// Resume a request paused by returning `Pause`.
pub fn resume_http_request() -> Unit raise HostError {
  check("resume_http_request", host().continue_stream(Request))
}

///|
/// Resume a response paused by returning `Pause`.
pub fn resume_http_response() -> Unit raise HostError {
  check("resume_http_response", host().continue_stream(Response))
}

///|
pub fn resume_downstream() -> Unit raise HostError {
  check("resume_downstream", host().continue_stream(Downstream))
}

///|
pub fn resume_upstream() -> Unit raise HostError {
  check("resume_upstream", host().continue_stream(Upstream))
}

///|
/// Reset the current HTTP stream (Envoy `resetStream`): the client sees the
/// connection or HTTP/2 stream aborted. The fallback when a response is
/// already on its way and a local response is no longer possible.
pub fn reset_http_stream() -> Unit raise HostError {
  check("reset_http_stream", host().close_stream(Response))
}

///|
pub fn close_downstream() -> Unit raise HostError {
  check("close_downstream", host().close_stream(Downstream))
}

///|
pub fn close_upstream() -> Unit raise HostError {
  check("close_upstream", host().close_stream(Upstream))
}

///|
/// Answer the request directly without contacting the upstream. Return
/// `Pause` from the current callback afterwards.
pub fn send_http_response(
  status_code : Int32,
  headers : Array[(String, String)],
  body : Bytes,
  details~ : String = "",
  grpc_status~ : Int32 = -1,
) -> Unit raise HostError {
  check(
    "send_http_response",
    host().send_local_response(
      status_code,
      details,
      body,
      serialize_map(headers),
      grpc_status,
    ),
  )
}

// ---- HTTP callouts --------------------------------------------------------

///|
/// The response to an HTTP callout, read eagerly before the callback runs.
pub(all) struct HttpCallResponse {
  status_code : Int32
  headers : Array[(String, String)]
  body : Bytes
  trailers : Array[(String, String)]
}

///|
/// Value of one response header (first match, names compared lower-case).
pub fn HttpCallResponse::header(
  self : HttpCallResponse,
  name : String,
) -> String? {
  let name = name.to_lower()
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
fn parse_status(s : String) -> Int32 {
  let mut n = 0
  for c in s {
    guard c >= '0' && c <= '9' && n < 1000 else { return 0 }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  n
}

///|
fn read_http_call_response(
  body_size : Int32,
  num_trailers : Int32,
) -> HttpCallResponse? raise HostError {
  let headers = get_header_map(HttpCallResponseHeaders)
  let mut status_code = 0
  for pair in headers {
    if pair.0 == ":status" {
      status_code = parse_status(pair.1)
      break
    }
  }
  let body = if body_size > 0 {
    get_buffer(HttpCallResponseBody, size=body_size)
  } else {
    b""
  }
  let trailers = if num_trailers > 0 {
    get_header_map(HttpCallResponseTrailers)
  } else {
    []
  }
  Some({ status_code, headers, body, trailers, })
}

///|
/// Send an HTTP request to the Envoy cluster `upstream`. `headers` must
/// contain `:method`, `:path` and `:authority`.
///
/// `callback` runs when the call finishes: `Some(response)` on a reply,
/// `None` when it timed out or the upstream could not be reached. Inside the
/// callback, follow-up calls (`resume_http_request`, `send_http_response`,
/// header edits) act on the stream that issued the callout. If the callback
/// raises, the root context's `error_policy` decides whether that paused
/// stream is resumed or rejected. Returns the callout token.
pub fn dispatch_http_call(
  upstream : String,
  headers : Array[(String, String)],
  body~ : Bytes = b"",
  trailers~ : Array[(String, String)] = [],
  timeout_ms~ : Int32 = 5000,
  callback : (HttpCallResponse?) -> Unit raise,
) -> Int32 raise HostError {
  let (st, token) = host().http_call(
    upstream,
    serialize_map(headers),
    body,
    serialize_map(trailers),
    timeout_ms,
  )
  check("dispatch_http_call", st)
  register_callout(token, callback)
  token
}

// ---- properties -------------------------------------------------------

///|
/// Read a host property such as `["request", "path"]` or
/// `["source", "address"]`. `None` if the property does not exist.
pub fn get_property(path : Array[String]) -> Bytes? raise HostError {
  let (st, data) = host().get_property(serialize_path(path))
  match st {
    Ok => Some(data)
    NotFound => None
    _ => raise HostError("get_property", st)
  }
}

///|
/// Read a property and decode it as UTF-8 text.
pub fn get_property_string(path : Array[String]) -> String? raise HostError {
  get_property(path).map(fn(b) { @utf8.decode_lossy(b) })
}

///|
pub fn set_property(
  path : Array[String],
  value : Bytes,
) -> Unit raise HostError {
  check("set_property", host().set_property(serialize_path(path), value))
}

// ---- shared data (per-VM key/value store with CAS) ----------------------

///|
/// Value and CAS version of a shared-data key, `None` if unset.
pub fn get_shared_data(key : String) -> (Bytes, Int32)? raise HostError {
  let (st, data, cas) = host().get_shared_data(key)
  match st {
    Ok => Some((data, cas))
    NotFound => None
    _ => raise HostError("get_shared_data", st)
  }
}

///|
/// Store a value. With `cas != 0` the write only succeeds if the key is
/// still at that version; otherwise it raises `HostError(_, CasMismatch)`.
pub fn set_shared_data(
  key : String,
  value : Bytes,
  cas~ : Int32 = 0,
) -> Unit raise HostError {
  check("set_shared_data", host().set_shared_data(key, value, cas))
}

// ---- shared queues ------------------------------------------------------

///|
pub fn register_shared_queue(name : String) -> Int32 raise HostError {
  let (st, id) = host().register_shared_queue(name)
  check("register_shared_queue", st)
  id
}

///|
pub fn resolve_shared_queue(
  vm_id : String,
  name : String,
) -> Int32 raise HostError {
  let (st, id) = host().resolve_shared_queue(vm_id, name)
  check("resolve_shared_queue", st)
  id
}

///|
pub fn enqueue_shared_queue(
  queue_id : Int32,
  data : Bytes,
) -> Unit raise HostError {
  check("enqueue_shared_queue", host().enqueue_shared_queue(queue_id, data))
}

///|
/// Next item of a queue, `None` when it is empty.
pub fn dequeue_shared_queue(queue_id : Int32) -> Bytes? raise HostError {
  let (st, data) = host().dequeue_shared_queue(queue_id)
  match st {
    Ok => Some(data)
    Empty => None
    _ => raise HostError("dequeue_shared_queue", st)
  }
}

// ---- lifecycle ----------------------------------------------------------

///|
/// Signal that a plugin which returned `false` from `on_plugin_done` has
/// finished shutting down.
pub fn done() -> Unit raise HostError {
  check("done", host().done())
}
