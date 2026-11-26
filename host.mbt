///|
/// The raw proxy-wasm host interface.
///
/// Inside Envoy/Istio/Higress the SDK talks to the real host through
/// `env.proxy_*` imports (see `host_wasm.mbt`). Every other target (js,
/// native, wasm-gc) has no proxy host, so tests install a simulated host
/// with `set_host` — the `proxytest` package provides one.
///
/// Byte-level arguments are already serialized in the ABI wire format, so a
/// host implementation only has to move bytes.
pub(open) trait Host {
  log(Self, LogLevel, String) -> Status
  get_log_level(Self) -> LogLevel
  get_current_time_nanos(Self) -> Int64
  set_tick_period_ms(Self, Int) -> Status
  get_buffer(Self, BufferType, Int, Int) -> (Status, Bytes)
  set_buffer(Self, BufferType, Int, Int, Bytes) -> Status
  get_map_pairs(Self, MapType) -> (Status, Bytes)
  set_map_pairs(Self, MapType, Bytes) -> Status
  get_map_value(Self, MapType, String) -> (Status, Bytes)
  replace_map_value(Self, MapType, String, String) -> Status
  add_map_value(Self, MapType, String, String) -> Status
  remove_map_value(Self, MapType, String) -> Status
  get_property(Self, Bytes) -> (Status, Bytes)
  set_property(Self, Bytes, Bytes) -> Status
  get_shared_data(Self, String) -> (Status, Bytes, Int)
  set_shared_data(Self, String, Bytes, Int) -> Status
  register_shared_queue(Self, String) -> (Status, Int)
  resolve_shared_queue(Self, String, String) -> (Status, Int)
  enqueue_shared_queue(Self, Int, Bytes) -> Status
  dequeue_shared_queue(Self, Int) -> (Status, Bytes)
  continue_stream(Self, StreamType) -> Status
  close_stream(Self, StreamType) -> Status
  send_local_response(Self, Int, String, Bytes, Bytes, Int) -> Status
  http_call(Self, String, Bytes, Bytes, Bytes, Int) -> (Status, Int)
  set_effective_context(Self, Int) -> Status
  done(Self) -> Status
  define_metric(Self, MetricType, String) -> (Status, Int)
  increment_metric(Self, Int, Int64) -> Status
  record_metric(Self, Int, UInt64) -> Status
  get_metric(Self, Int) -> (Status, UInt64)
}

///|
let current_host : Ref[&Host] = { val: default_host() }

///|
/// Replace the host the SDK talks to. Used by simulated hosts in tests;
/// plugins running inside a proxy never need to call this.
pub fn set_host(host : &Host) -> Unit {
  current_host.val = host
}

///|
fn host() -> &Host {
  current_host.val
}
