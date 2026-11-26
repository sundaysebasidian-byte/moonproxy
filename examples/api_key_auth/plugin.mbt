///|
/// API-key authentication.
///
/// Configuration:
/// ```json
/// {"header": "x-api-key", "keys": {"k-123": "alice", "k-456": "bob"}}
/// ```
///
/// - no key: 401 with `www-authenticate`;
/// - unknown key: 403;
/// - valid key: the key header is removed (it never reaches the upstream)
///   and `x-consumer: <name>` is added.
///
/// The plugin runs with `FailClosed`: if anything unexpected fails, the
/// request is rejected rather than let through unauthenticated.

///|
priv struct AuthRoot {
  mut header : String
  mut keys : Map[String, String]
  mut allowed : @moonproxy.Metric?
  mut denied : @moonproxy.Metric?
}

///|
impl @moonproxy.RootContext for AuthRoot with on_plugin_start(self, _) {
  let cfg = @json.parse(
    @utf8.decode_lossy(@moonproxy.get_plugin_configuration()),
  )
  guard cfg is { "keys": Object(keys), .. } else {
    @moonproxy.log_error("api_key_auth: configuration needs a \"keys\" object")
    return false
  }
  // Parse everything first: a rejected reconfiguration must leave the
  // previous, working key set in place.
  let parsed : Map[String, String] = {}
  for key, consumer in keys {
    guard consumer is String(name) else {
      @moonproxy.log_error("api_key_auth: consumer of a key must be a string")
      return false
    }
    parsed[key] = name
  }
  self.header = match cfg {
    { "header": String(h), .. } if h != "" => h.to_lower()
    _ => "x-api-key"
  }
  self.keys = parsed
  self.allowed = Some(@moonproxy.Metric::counter("api_key_auth.allowed"))
  self.denied = Some(@moonproxy.Metric::counter("api_key_auth.denied"))
  true
}

///|
/// A bug in the plugin must reject the request, not let it through.
impl @moonproxy.RootContext for AuthRoot with error_policy(_) {
  FailClosed
}

///|
impl @moonproxy.RootContext for AuthRoot with new_http_context(self, _) {
  Some(AuthStream::{ root: self })
}

///|
priv struct AuthStream {
  root : AuthRoot
}

///|
fn bump(m : @moonproxy.Metric?) -> Unit raise {
  if m is Some(metric) {
    metric.increment()
  }
}

///|
fn reject(code : Int, msg : String) -> Unit raise {
  @moonproxy.send_http_response(
    code,
    [("content-type", "application/json"), ("www-authenticate", "ApiKey")],
    @utf8.encode("{\"error\":\"\{msg}\"}"),
    details="api_key_auth",
  )
}

///|
impl @moonproxy.HttpContext for AuthStream with on_request_headers(self, _, _) {
  let root = self.root
  guard @moonproxy.get_request_header(root.header) is Some(key) else {
    bump(root.denied)
    reject(401, "missing api key")
    return Pause
  }
  guard root.keys.get(key) is Some(consumer) else {
    bump(root.denied)
    reject(403, "invalid api key")
    return Pause
  }
  @moonproxy.remove_request_header(root.header)
  @moonproxy.replace_request_header("x-consumer", consumer)
  bump(root.allowed)
  Continue
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) {
    AuthRoot::{ header: "x-api-key", keys: Map([]), allowed: None, denied: None }
  })
}
