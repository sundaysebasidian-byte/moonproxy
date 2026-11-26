///|
/// Placeholder host for targets without a proxy-wasm runtime.
priv struct NoHost {}

///|
fn[T] no_host(op : String) -> T {
  abort("moonproxy: no proxy-wasm host for `\{op}`; install one with set_host")
}

///|
impl Host for NoHost with log(_, _, _) { no_host("log") }

///|
impl Host for NoHost with get_log_level(_) { no_host("get_log_level") }

///|
impl Host for NoHost with get_current_time_nanos(_) {
  no_host("get_current_time_nanos")
}

///|
impl Host for NoHost with set_tick_period_ms(_, _) {
  no_host("set_tick_period_ms")
}

///|
impl Host for NoHost with get_buffer(_, _, _, _) { no_host("get_buffer") }

///|
impl Host for NoHost with set_buffer(_, _, _, _, _) { no_host("set_buffer") }

///|
impl Host for NoHost with get_map_pairs(_, _) { no_host("get_map_pairs") }

///|
impl Host for NoHost with set_map_pairs(_, _, _) { no_host("set_map_pairs") }

///|
impl Host for NoHost with get_map_value(_, _, _) { no_host("get_map_value") }

///|
impl Host for NoHost with replace_map_value(_, _, _, _) {
  no_host("replace_map_value")
}

///|
impl Host for NoHost with add_map_value(_, _, _, _) { no_host("add_map_value") }

///|
impl Host for NoHost with remove_map_value(_, _, _) {
  no_host("remove_map_value")
}

///|
impl Host for NoHost with get_property(_, _) { no_host("get_property") }

///|
impl Host for NoHost with set_property(_, _, _) { no_host("set_property") }

///|
impl Host for NoHost with get_shared_data(_, _) { no_host("get_shared_data") }

///|
impl Host for NoHost with set_shared_data(_, _, _, _) {
  no_host("set_shared_data")
}

///|
impl Host for NoHost with register_shared_queue(_, _) {
  no_host("register_shared_queue")
}

///|
impl Host for NoHost with resolve_shared_queue(_, _, _) {
  no_host("resolve_shared_queue")
}

///|
impl Host for NoHost with enqueue_shared_queue(_, _, _) {
  no_host("enqueue_shared_queue")
}

///|
impl Host for NoHost with dequeue_shared_queue(_, _) {
  no_host("dequeue_shared_queue")
}

///|
impl Host for NoHost with continue_stream(_, _) { no_host("continue_stream") }

///|
impl Host for NoHost with close_stream(_, _) { no_host("close_stream") }

///|
impl Host for NoHost with send_local_response(_, _, _, _, _, _) {
  no_host("send_local_response")
}

///|
impl Host for NoHost with http_call(_, _, _, _, _, _) { no_host("http_call") }

///|
impl Host for NoHost with set_effective_context(_, _) {
  no_host("set_effective_context")
}

///|
impl Host for NoHost with done(_) { no_host("done") }

///|
impl Host for NoHost with define_metric(_, _, _) { no_host("define_metric") }

///|
impl Host for NoHost with increment_metric(_, _, _) {
  no_host("increment_metric")
}

///|
impl Host for NoHost with record_metric(_, _, _) { no_host("record_metric") }

///|
impl Host for NoHost with get_metric(_, _) { no_host("get_metric") }

///|
fn default_host() -> &Host {
  NoHost::{  }
}

///|
/// Called by the host to allocate guest memory. Only meaningful on wasm.
pub fn memory_allocate(_size : Int) -> Int {
  no_host("memory_allocate")
}
