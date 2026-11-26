///|
/// The plugin from the README's quick start, kept here so that CI compiles,
/// tests and loads into Envoy exactly what the README shows.
priv struct Root {}

///|
impl @moonproxy.RootContext for Root with fn new_http_context(_, _) {
  Some(Stream::{ })
}

///|
priv struct Stream {}

///|
impl @moonproxy.HttpContext for Stream with fn on_request_headers(_, _, _) {
  if @moonproxy.get_request_header("x-api-key") is None {
    @moonproxy.send_http_response(401, [], b"missing key")
    return Pause
  }
  @moonproxy.add_request_header("x-checked-by", "moonbit")
  Continue
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) { Root::{ } })
}
