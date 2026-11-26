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
  fn log(Self, LogLevel, String) -> Status
  fn get_log_level(Self) -> LogLevel
  fn get_current_time_nanos(Self) -> Int64
  fn set_tick_period_ms(Self, Int32) -> Status
  fn get_buffer(Self, BufferType, Int32, Int32) -> (Status, Bytes)
  fn set_buffer(Self, BufferType, Int32, Int32, Bytes) -> Status
  fn get_map_pairs(Self, MapType) -> (Status, Bytes)
  fn set_map_pairs(Self, MapType, Bytes) -> Status
  fn get_map_value(Self, MapType, String) -> (Status, Bytes)
  fn replace_map_value(Self, MapType, String, String) -> Status
  fn add_map_value(Self, MapType, String, String) -> Status
  fn remove_map_value(Self, MapType, String) -> Status
  fn get_property(Self, Bytes) -> (Status, Bytes)
  fn set_property(Self, Bytes, Bytes) -> Status
  fn get_shared_data(Self, String) -> (Status, Bytes, Int32)
  fn set_shared_data(Self, String, Bytes, Int32) -> Status
  fn register_shared_queue(Self, String) -> (Status, Int32)
  fn resolve_shared_queue(Self, String, String) -> (Status, Int32)
  fn enqueue_shared_queue(Self, Int32, Bytes) -> Status
  fn dequeue_shared_queue(Self, Int32) -> (Status, Bytes)
  fn continue_stream(Self, StreamType) -> Status
  fn close_stream(Self, StreamType) -> Status
  fn send_local_response(Self, Int32, String, Bytes, Bytes, Int32) -> Status
  fn http_call(Self, String, Bytes, Bytes, Bytes, Int32) -> (Status, Int32)
  fn set_effective_context(Self, Int32) -> Status
  fn done(Self) -> Status
  fn define_metric(Self, MetricType, String) -> (Status, Int32)
  fn increment_metric(Self, Int32, Int64) -> Status
  fn record_metric(Self, Int32, UInt64) -> Status
  fn get_metric(Self, Int32) -> (Status, UInt64)
}

///|
let current_host : Ref[&Host] = { val: default_host(), }

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
