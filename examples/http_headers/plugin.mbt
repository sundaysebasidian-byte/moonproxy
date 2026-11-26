///|
/// Smallest useful plugin: tag every response and log the request line.
///
/// Plugin configuration (optional): `{"header": "x-powered-by", "value": "moonbit"}`

///|
priv struct HeadersRoot {
  mut name : String
  mut value : String
}

///|
impl @moonproxy.RootContext for HeadersRoot with fn on_plugin_start(self, _) {
  let raw = @moonproxy.get_plugin_configuration()
  if raw.length() == 0 {
    return true
  }
  let cfg = @json.parse(@utf8.decode_lossy(raw))
  if cfg is { "header": String(h), .. } {
    self.name = h.to_lower()
  }
  if cfg is { "value": String(v), .. } {
    self.value = v
  }
  true
}

///|
impl @moonproxy.RootContext for HeadersRoot with fn new_http_context(self, _) {
  Some(HeadersStream::{ root: self, })
}

///|
priv struct HeadersStream {
  root : HeadersRoot
}

///|
impl @moonproxy.HttpContext for HeadersStream with fn on_request_headers(
  _,
  _,
  _,
) {
  let verb = @moonproxy.get_request_header(":method").unwrap_or("-")
  let path = @moonproxy.get_request_header(":path").unwrap_or("-")
  @moonproxy.log_info("\{verb} \{path}")
  Continue
}

///|
impl @moonproxy.HttpContext for HeadersStream with fn on_response_headers(
  self,
  _,
  _,
) {
  @moonproxy.replace_response_header(self.root.name, self.root.value)
  Continue
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) {
    HeadersRoot::{ name: "x-powered-by", value: "moonproxy", }
  })
}
