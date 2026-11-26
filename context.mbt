///|
/// A plugin instance. One root context exists per plugin configuration;
/// it creates a stream context for every HTTP request or TCP connection.
/// Every method has a default, so implement only the callbacks you need.
pub(open) trait RootContext {
  /// The VM started; `config_size` bytes of VM configuration are available
  /// via `get_vm_configuration()`. Return `false` to fail the start.
  fn on_vm_start(Self, config_size : Int32) -> Bool raise = _
  /// The plugin was (re)configured; read it with `get_plugin_configuration()`.
  /// Return `false` to reject the configuration.
  fn on_plugin_start(Self, config_size : Int32) -> Bool raise = _
  /// Called every tick period set by `set_tick_period_ms`.
  fn on_tick(Self) -> Unit raise = _
  /// A shared queue this plugin registered has data.
  fn on_queue_ready(Self, queue_id : Int32) -> Unit raise = _
  /// The host is shutting the plugin down. Return `false` to delay the
  /// shutdown until `done()` is called.
  fn on_plugin_done(Self) -> Bool raise = _
  /// Create the per-request context when this plugin runs as an HTTP
  /// filter. Called lazily, on the stream's first HTTP callback.
  fn new_http_context(Self, context_id : Int32) -> &HttpContext? = _
  /// Create the per-connection context when this plugin runs as a network
  /// (TCP) filter. Called lazily, on `on_new_connection`.
  fn new_tcp_context(Self, context_id : Int32) -> &TcpContext? = _
  /// What to do when a callback of this plugin raises (default `FailOpen`).
  /// Authentication and other security plugins should return `FailClosed`.
  fn error_policy(Self) -> ErrorPolicy = _
}

///|
/// How errors raised by plugin callbacks are handled. Either way the error
/// is logged at `error` level with the callback name and context id.
#derive(Debug, Eq)
pub(all) enum ErrorPolicy {
  /// Let the request or connection continue as if the callback had
  /// returned `Continue` (a paused request is resumed).
  FailOpen
  /// Reject: an HTTP stream gets a local 500 response, a TCP connection
  /// is closed.
  FailClosed
}

///|
impl RootContext with fn on_vm_start(_, _) {
  true
}

///|
impl RootContext with fn on_plugin_start(_, _) {
  true
}

///|
impl RootContext with fn on_tick(_) {
  ()
}

///|
impl RootContext with fn on_queue_ready(_, _) {
  ()
}

///|
impl RootContext with fn on_plugin_done(_) {
  true
}

///|
impl RootContext with fn new_http_context(_, _) {
  None
}

///|
impl RootContext with fn new_tcp_context(_, _) {
  None
}

///|
impl RootContext with fn error_policy(_) {
  FailOpen
}

///|
/// Per-request callbacks of an HTTP filter.
pub(open) trait HttpContext {
  fn on_request_headers(Self, num_headers : Int32, end_of_stream : Bool) -> Action raise = _
  fn on_request_body(Self, body_size : Int32, end_of_stream : Bool) -> Action raise = _
  fn on_request_trailers(Self, num_trailers : Int32) -> Action raise = _
  fn on_response_headers(Self, num_headers : Int32, end_of_stream : Bool) -> Action raise = _
  fn on_response_body(Self, body_size : Int32, end_of_stream : Bool) -> Action raise = _
  fn on_response_trailers(Self, num_trailers : Int32) -> Action raise = _
  /// The access-log phase: headers, trailers and properties are readable.
  fn on_log(Self) -> Unit raise = _
  /// The stream is gone; release per-request state.
  fn on_done(Self) -> Unit raise = _
}

///|
impl HttpContext with fn on_request_headers(_, _, _) {
  Continue
}

///|
impl HttpContext with fn on_request_body(_, _, _) {
  Continue
}

///|
impl HttpContext with fn on_request_trailers(_, _) {
  Continue
}

///|
impl HttpContext with fn on_response_headers(_, _, _) {
  Continue
}

///|
impl HttpContext with fn on_response_body(_, _, _) {
  Continue
}

///|
impl HttpContext with fn on_response_trailers(_, _) {
  Continue
}

///|
impl HttpContext with fn on_log(_) {
  ()
}

///|
impl HttpContext with fn on_done(_) {
  ()
}

///|
/// Per-connection callbacks of a network (TCP) filter.
pub(open) trait TcpContext {
  fn on_new_connection(Self) -> Action raise = _
  fn on_downstream_data(Self, data_size : Int32, end_of_stream : Bool) -> Action raise = _
  fn on_downstream_close(Self, peer : PeerType) -> Unit raise = _
  fn on_upstream_data(Self, data_size : Int32, end_of_stream : Bool) -> Action raise = _
  fn on_upstream_close(Self, peer : PeerType) -> Unit raise = _
  fn on_log(Self) -> Unit raise = _
  fn on_done(Self) -> Unit raise = _
}

///|
impl TcpContext with fn on_new_connection(_) {
  Continue
}

///|
impl TcpContext with fn on_downstream_data(_, _, _) {
  Continue
}

///|
impl TcpContext with fn on_downstream_close(_, _) {
  ()
}

///|
impl TcpContext with fn on_upstream_data(_, _, _) {
  Continue
}

///|
impl TcpContext with fn on_upstream_close(_, _) {
  ()
}

///|
impl TcpContext with fn on_log(_) {
  ()
}

///|
impl TcpContext with fn on_done(_) {
  ()
}

///|
pub extend ErrorPolicy with Debug::{to_repr}

///|
pub extend ErrorPolicy with Eq::{equal, not_equal}
