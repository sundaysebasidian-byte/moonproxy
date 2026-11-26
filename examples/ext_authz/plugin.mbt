///|
/// External authorization through an HTTP callout.
///
/// Configuration:
/// ```json
/// {
///   "cluster": "authz",            // Envoy cluster of the auth service
///   "authority": "authz.internal", // :authority sent to it
///   "path": "/check",
///   "timeout_ms": 500,
///   "forward": ["authorization", "cookie"],
///   "copy_back": ["x-user-id", "x-user-roles"]
/// }
/// ```
///
/// Each request is paused while `GET <path>` goes to the auth service with
/// the `forward` headers plus `x-original-method` and `x-original-uri`.
/// Client-supplied copies of the `copy_back` headers are removed before
/// anything else, so they can never be forged, whichever way the request
/// goes on. The request body (if any) is held until the verdict arrives.
/// - 2xx: the `copy_back` headers of the answer are set on the request and
///   the request resumes;
/// - 401 / 403: that status goes back to the client with the service's body;
/// - anything else, or a timeout: 503, unless `"fail_open": true`.

///|
priv struct AuthzConfig {
  cluster : String
  authority : String
  path : String
  timeout_ms : Int32
  forward : Array[String]
  copy_back : Array[String]
  fail_open : Bool
}

///|
fn strings(v : Json?) -> Array[String] {
  match v {
    Some(Array(items)) =>
      items.filter_map(fn(j) {
        if j is String(s) {
          Some(s.to_lower())
        } else {
          None
        }
      })
    _ => []
  }
}

///|
fn parse_config(text : String) -> AuthzConfig? {
  let cfg = @json.parse(text) catch { _ => return None }
  guard cfg is Object(o) && o.get("cluster") is Some(String(cluster)) else {
    return None
  }
  let str = fn(k, d) { if o.get(k) is Some(String(s)) { s } else { d } }
  let timeout = if o.get("timeout_ms") is Some(Number(n, ..)) && n > 0.0 {
    n.to_int()
  } else {
    1000
  }
  Some({
    cluster,
    authority: str("authority", cluster),
    path: str("path", "/"),
    timeout_ms: timeout,
    forward: strings(o.get("forward")),
    copy_back: strings(o.get("copy_back")),
    fail_open: o.get("fail_open") is Some(True),
  })
}

///|
priv struct AuthzRoot {
  mut config : AuthzConfig?
  mut allowed : @moonproxy.Metric?
  mut denied : @moonproxy.Metric?
  mut failed : @moonproxy.Metric?
}

///|
impl @moonproxy.RootContext for AuthzRoot with fn on_plugin_start(self, _) {
  let text = @utf8.decode_lossy(@moonproxy.get_plugin_configuration())
  guard parse_config(text) is Some(c) else {
    @moonproxy.log_error("ext_authz: configuration needs a \"cluster\" string")
    return false
  }
  self.config = Some(c)
  self.allowed = Some(@moonproxy.Metric::counter("ext_authz.allowed"))
  self.denied = Some(@moonproxy.Metric::counter("ext_authz.denied"))
  self.failed = Some(@moonproxy.Metric::counter("ext_authz.failed"))
  true
}

///|
impl @moonproxy.RootContext for AuthzRoot with fn new_http_context(self, _) {
  Some(AuthzStream::{ root: self, pending: false, })
}

///|
/// An authorization plugin must never let a request through because of a
/// bug in the plugin itself.
impl @moonproxy.RootContext for AuthzRoot with fn error_policy(_) {
  FailClosed
}

///|
priv struct AuthzStream {
  root : AuthzRoot
  /// True while the callout is in flight. Envoy does not run the body and
  /// trailer callbacks while the headers are paused, but a host configured
  /// with `allow_on_headers_stop_iteration` does; they then keep the request
  /// paused, since a `Continue` there would forward it before the verdict.
  mut pending : Bool
}

///|
fn bump(m : @moonproxy.Metric?) -> Unit raise {
  if m is Some(metric) {
    metric.increment()
  }
}

///|
impl @moonproxy.HttpContext for AuthzStream with fn on_request_headers(
  self,
  _,
  _,
) {
  // A running plugin always has a configuration (on_plugin_start rejects a
  // bad one); if not, the error policy (FailClosed) rejects the request.
  guard self.root.config is Some(cfg) else { fail("ext_authz: not configured") }
  // Drop client-supplied identity headers up front, so that no later path
  // (allow, fail-open, plugin error) can forward a forged one.
  for name in cfg.copy_back {
    @moonproxy.remove_request_header(name)
  }
  let headers = [
    (":method", "GET"),
    (":path", cfg.path),
    (":authority", cfg.authority),
    (
      "x-original-method",
      @moonproxy.get_request_header(":method").unwrap_or(""),
    ),
    ("x-original-uri", @moonproxy.get_request_header(":path").unwrap_or("")),
  ]
  let all = @moonproxy.get_request_headers()
  for name in cfg.forward {
    let values = all.filter(fn(kv) { kv.0 == name })
    // With two values the auth service and the upstream could each pick a
    // different one, so the identity checked might not be the one used.
    if values.length() > 1 {
      bump(self.root.denied)
      @moonproxy.send_http_response(
        400,
        [("content-type", "text/plain")],
        b"duplicate \{name} header\n",
        details="ext_authz_duplicate_header",
      )
      return Pause
    }
    if values is [(_, v)] {
      headers.push((name, v))
    }
  }
  let root = self.root
  let _ = @moonproxy.dispatch_http_call(
    cfg.cluster,
    headers,
    timeout_ms=cfg.timeout_ms,
    fn(answer) raise {
      self.pending = false
      on_verdict(root, cfg, answer)
    },
  )
  self.pending = true
  Pause
}

///|
impl @moonproxy.HttpContext for AuthzStream with fn on_request_body(self, _, _) {
  if self.pending {
    Pause
  } else {
    Continue
  }
}

///|
impl @moonproxy.HttpContext for AuthzStream with fn on_request_trailers(self, _) {
  if self.pending {
    Pause
  } else {
    Continue
  }
}

///|
fn on_verdict(
  root : AuthzRoot,
  cfg : AuthzConfig,
  answer : @moonproxy.HttpCallResponse?,
) -> Unit raise {
  let status = match answer {
    Some(r) => r.status_code
    None => 0
  }
  if answer is Some(r) && status >= 200 && status < 300 {
    for name in cfg.copy_back {
      for kv in r.headers {
        if kv.0 == name {
          @moonproxy.add_request_header(name, kv.1)
        }
      }
    }
    bump(root.allowed)
    @moonproxy.resume_http_request()
  } else if answer is Some(r) && (status == 401 || status == 403) {
    bump(root.denied)
    @moonproxy.send_http_response(
      status,
      [("content-type", r.header("content-type").unwrap_or("text/plain"))],
      r.body,
      details="ext_authz_denied",
    )
  } else {
    bump(root.failed)
    @moonproxy.log_warn(
      if status == 0 {
        "ext_authz: auth service timed out or is unreachable"
      } else {
        "ext_authz: auth service answered \{status}"
      },
    )
    if cfg.fail_open {
      @moonproxy.resume_http_request()
    } else {
      @moonproxy.send_http_response(
        503,
        [("content-type", "text/plain")],
        b"authorization service unavailable",
        details="ext_authz_unavailable",
      )
    }
  }
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) {
    AuthzRoot::{ config: None, allowed: None, denied: None, failed: None, }
  })
}
