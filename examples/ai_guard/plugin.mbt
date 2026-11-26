///|
/// Policy gateway for OpenAI-compatible LLM traffic.
///
/// Configuration:
/// ```json
/// {
///   "allowed_models": ["gpt-4o-mini", "qwen-plus"],
///   "deny_words": ["internal-only", "password"],
///   "max_tokens": 1024,
///   "max_choices": 1,
///   "paths": ["/chat/completions", "/completions", "/responses"]
/// }
/// ```
///
/// A `POST` whose path ends with one of `paths` (the default list above) is
/// checked. The path is normalised first (query dropped, `%XX` decoded,
/// `\` read as `/`, `;params`, `.` and `..` segments and repeated or
/// trailing `/` resolved, lower-cased), so `/v1/Chat//complet%69ons/` and
/// `/v1/chat/completions/x/..` are checked too. Turning on Envoy's own
/// `normalize_path` and `merge_slashes` in the HTTP connection manager is
/// still recommended, so that the backend routes on the same path. The headers continue at once,
/// without `content-length` (the body may be rewritten; Envoy then frames it
/// itself). The body is buffered to the end of the stream, so none of it
/// reaches the upstream before the verdict:
/// - unparsable body or no `model`: 400 `invalid_request`;
/// - `model` not in `allowed_models` (when the list is non-empty), or a
///   deny word (case-insensitive) in `messages`, `prompt` or `input`: 400
///   `policy_violation`, with the reason, before any token is spent;
/// - `n` or `best_of` above `max_choices` (default 1): 400
///   `policy_violation`; not a positive integer: 400 `invalid_request`;
/// - a token limit (`max_tokens`, `max_completion_tokens`,
///   `max_output_tokens`) that is not a positive number: 400
///   `invalid_request`, since a backend may read a string such as `"99999"`
///   in its own way;
/// - a token limit above the cap, `null`, or none at all: set to the cap (as
///   `max_output_tokens` on `/responses`, `max_tokens` elsewhere) and the
///   body is re-serialised.
///
/// The headers are not held back because proxy-wasm hosts turn a `Pause`
/// from the headers callback into "stop everything" (Envoy's
/// `StopAllIterationAndWatermark`): the body callbacks would then not run
/// until the stream is resumed. The price is that the upstream sees the
/// request headers, and may open the request, before the verdict; a rejected
/// request is then cancelled upstream with no body ever sent.
///
/// Metrics: `ai_guard.allowed`, `ai_guard.blocked`, and the histogram
/// `ai_guard.prompt_chars`.

///|
priv struct Policy {
  allowed_models : Array[String]
  deny_words : Array[String]
  max_tokens : Int32
  max_choices : Int32
  paths : Array[String]
}

///|
fn parse_policy(text : String) -> Policy? {
  let cfg = @json.parse(if text == "" { "{}" } else { text }) catch {
    _ => return None
  }
  guard cfg is Object(o) else { return None }
  let list = fn(k : String, lower : Bool) -> Array[String] {
    match o.get(k) {
      Some(Array(xs)) =>
        xs.filter_map(fn(x) {
          if x is String(s) {
            Some(if lower { s.to_lower() } else { s })
          } else {
            None
          }
        })
      _ => []
    }
  }
  let max_tokens = if o.get("max_tokens") is Some(Number(n, ..)) && n >= 1.0 {
    n.to_int()
  } else {
    4096
  }
  let max_choices = if o.get("max_choices") is Some(Number(n, ..)) && n >= 1.0 {
    n.to_int()
  } else {
    1
  }
  let paths = list("paths", true).map(normalize_path)
  Some({
    max_choices,
    allowed_models: list("allowed_models", false),
    deny_words: list("deny_words", true),
    max_tokens,
    paths: if paths.is_empty() {
      ["/chat/completions", "/completions", "/responses"]
    } else {
      paths
    },
  })
}

///|
priv enum Verdict {
  Allow(body~ : String, model~ : String, prompt_chars~ : Int32)
  Reject(kind~ : String, reason~ : String)
}

///|
fn hex_value(c : Char) -> Int32? {
  match c {
    '0'..<='9' => Some(c.to_int() - '0'.to_int())
    'a'..<='f' => Some(c.to_int() - 'a'.to_int() + 10)
    'A'..<='F' => Some(c.to_int() - 'A'.to_int() + 10)
    _ => None
  }
}

///|
/// The form a backend most likely routes on: no query, `%XX` decoded
/// (ASCII only), no empty segments, no trailing `/`, lower case.
fn normalize_path(raw : String) -> String {
  let chars = raw.to_array()
  let out = StringBuilder()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '?' || c == '#' {
      break
    }
    if c == '%' && i + 2 < chars.length() {
      if hex_value(chars[i + 1]) is Some(h) &&
        hex_value(chars[i + 2]) is Some(l) {
        let v = h * 16 + l
        if v < 128 {
          out.write_char(if v == 0x5c { '/' } else { Int32::unsafe_to_char(v) })
          i += 3
          continue
        }
      }
    }
    out.write_char(if c == '\\' { '/' } else { c })
    i += 1
  }
  // `;params` are dropped per segment, as servlet-style backends do; `\`
  // counts as `/` and `.` / `..` segments are resolved (RFC 3986
  // remove_dot_segments), as most HTTP servers do before routing.
  let segments : Array[String] = []
  for seg in out.to_string().to_lower().split("/") {
    let s = match seg.find(";") {
      Some(i) => seg[:i].to_owned()
      None => seg.to_owned()
    }
    match s {
      "" | "." => ()
      ".." => { let _ = segments.pop() }
      _ => segments.push(s)
    }
  }
  "/" + segments.join("/")
}

///|
/// Text of a message `content`: a string, or an array of strings and
/// `{"type": "text", "text": ...}` parts.
fn content_texts(content : Json, out : Array[String]) -> Unit {
  match content {
    String(s) => out.push(s)
    Array(parts) =>
      for p in parts {
        match p {
          String(s) => out.push(s)
          { "text": String(s), .. } => out.push(s)
          { "content": c, .. } => content_texts(c, out)
          _ => ()
        }
      }
    _ => ()
  }
}

///|
/// All prompt text of a request: chat `messages`, legacy `prompt`, and the
/// Responses API `input` (a string or a list of messages / parts).
fn prompt_texts(o : Map[String, Json]) -> Array[String] {
  let out = []
  if o.get("messages") is Some(Array(ms)) {
    for m in ms {
      if m is { "content": c, .. } {
        content_texts(c, out)
      }
    }
  }
  for key in ["prompt", "input", "instructions"] {
    if o.get(key) is Some(v) {
      content_texts(v, out)
    }
  }
  out
}

///|
/// The whole decision, kept pure so it can be tested without a host.
///
/// `limit_field` is the token-limit field to add when the request has none.
fn evaluate(
  policy : Policy,
  body : String,
  limit_field~ : String = "max_tokens",
) -> Verdict {
  let req = @json.parse(body) catch {
    _ => return Reject(kind="invalid_request", reason="body is not valid JSON")
  }
  guard req is Object(o) && o.get("model") is Some(String(model)) else {
    return Reject(kind="invalid_request", reason="missing \"model\"")
  }
  if !policy.allowed_models.is_empty() && !policy.allowed_models.contains(model) {
    return Reject(
      kind="policy_violation",
      reason="model \{model} is not allowed",
    )
  }
  let texts = prompt_texts(o)
  let mut chars = 0
  for t in texts {
    chars += t.length()
    let lower = t.to_lower()
    for w in policy.deny_words {
      if lower.contains(w) {
        return Reject(
          kind="policy_violation",
          reason="prompt contains a blocked term",
        )
      }
    }
  }
  // `n` / `best_of` multiply the tokens a request can spend.
  for key in ["n", "best_of"] {
    match o.get(key) {
      None | Some(Null) => ()
      Some(Number(n, ..)) if n >= 1.0 && n == n.floor() =>
        if n > policy.max_choices.to_double() {
          return Reject(
            kind="policy_violation",
            reason="\"\{key}\" above \{policy.max_choices}",
          )
        }
      Some(_) =>
        return Reject(
          kind="invalid_request",
          reason="\"\{key}\" must be a positive integer",
        )
    }
  }
  let cap = policy.max_tokens.to_double()
  let mut capped = false
  let mut limited = false
  for key in ["max_tokens", "max_completion_tokens", "max_output_tokens"] {
    match o.get(key) {
      None => ()
      Some(Null) => {
        o[key] = Json::number(cap)
        capped = true
        limited = true
      }
      Some(Number(n, ..)) if n >= 1.0 => {
        if n > cap {
          o[key] = Json::number(cap)
          capped = true
        }
        limited = true
      }
      Some(_) =>
        return Reject(
          kind="invalid_request",
          reason="\"\{key}\" must be a positive number",
        )
    }
  }
  if !limited {
    o[limit_field] = Json::number(cap)
    capped = true
  }
  let out = if capped { req.stringify() } else { body }
  Allow(body=out, model~, prompt_chars=chars)
}

///|
fn error_body(kind : String, reason : String) -> Bytes {
  let j : Json = {
    "error": { "type": Json::string(kind), "message": Json::string(reason) },
  }
  @utf8.encode(j.stringify())
}

///|
priv struct GuardRoot {
  mut policy : Policy?
  mut allowed : @moonproxy.Metric?
  mut blocked : @moonproxy.Metric?
  mut prompt_chars : @moonproxy.Metric?
}

///|
impl @moonproxy.RootContext for GuardRoot with fn on_plugin_start(self, _) {
  let text = @utf8.decode_lossy(@moonproxy.get_plugin_configuration())
  guard parse_policy(text) is Some(p) else {
    @moonproxy.log_error("ai_guard: configuration must be a JSON object")
    return false
  }
  self.policy = Some(p)
  self.allowed = Some(@moonproxy.Metric::counter("ai_guard.allowed"))
  self.blocked = Some(@moonproxy.Metric::counter("ai_guard.blocked"))
  self.prompt_chars = Some(
    @moonproxy.Metric::histogram("ai_guard.prompt_chars"),
  )
  true
}

///|
/// A bug in the plugin must reject the request, not let it through.
impl @moonproxy.RootContext for GuardRoot with fn error_policy(_) {
  FailClosed
}

///|
impl @moonproxy.RootContext for GuardRoot with fn new_http_context(self, _) {
  Some(GuardStream::{
    root: self,
    inspecting: false,
    limit_field: "max_tokens",
  })
}

///|
priv struct GuardStream {
  root : GuardRoot
  mut inspecting : Bool
  mut limit_field : String
}

///|
impl @moonproxy.HttpContext for GuardStream with fn on_request_headers(
  self,
  _,
  end_of_stream,
) {
  guard self.root.policy is Some(policy) else { return Continue }
  let verb = @moonproxy.get_request_header(":method").unwrap_or("")
  let path = normalize_path(
    @moonproxy.get_request_header(":path").unwrap_or(""),
  )
  if verb != "POST" || !policy.paths.iter().any(fn(p) { path.has_suffix(p) }) {
    return Continue
  }
  if end_of_stream {
    // No body at all: there is no model to check.
    @moonproxy.send_http_response(
      400,
      [("content-type", "application/json")],
      error_body("invalid_request", "missing request body"),
      details="ai_guard_invalid_request",
    )
    return Pause
  }
  self.inspecting = true
  if path.has_suffix("/responses") {
    self.limit_field = "max_output_tokens"
  }
  // The body may be rewritten, so its old length must not reach upstream.
  @moonproxy.remove_request_header("content-length")
  Continue
}

///|
impl @moonproxy.HttpContext for GuardStream with fn on_request_body(
  self,
  _,
  eos,
) {
  if !self.inspecting {
    return Continue
  }
  if !eos {
    return Pause
  }
  self.inspect()
}

///|
/// A request with trailers (HTTP/2, gRPC-web) ends with them, not with a
/// data frame marked end-of-stream, so the check must also run here or the
/// buffered body would be forwarded unchecked.
impl @moonproxy.HttpContext for GuardStream with fn on_request_trailers(self, _) {
  if !self.inspecting {
    return Continue
  }
  self.inspect()
}

///|
fn GuardStream::inspect(self : GuardStream) -> @moonproxy.Action raise {
  self.inspecting = false
  guard self.root.policy is Some(policy) else { return Continue }
  let body = @utf8.decode_lossy(@moonproxy.get_request_body())
  match evaluate(policy, body, limit_field=self.limit_field) {
    Reject(kind~, reason~) => {
      if self.root.blocked is Some(m) {
        m.increment()
      }
      @moonproxy.send_http_response(
        400,
        [("content-type", "application/json")],
        error_body(kind, reason),
        details="ai_guard_" + kind,
      )
      Pause
    }
    Allow(body=out, model~, prompt_chars~) => {
      if out != body {
        @moonproxy.replace_request_body(@utf8.encode(out))
      }
      ignore(model)
      if self.root.allowed is Some(m) {
        m.increment()
      }
      if self.root.prompt_chars is Some(m) {
        m.record(prompt_chars.to_uint64())
      }
      Continue
    }
  }
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) {
    GuardRoot::{
      policy: None,
      allowed: None,
      blocked: None,
      prompt_chars: None,
    }
  })
}
