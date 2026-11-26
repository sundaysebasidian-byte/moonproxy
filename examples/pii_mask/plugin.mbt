///|
/// Masks personal data in text and JSON responses before they leave the
/// proxy (see `mask.mbt` for the rules).
///
/// The response body is buffered until end of stream so that a number
/// split across two chunks is still found; Envoy's buffer limit applies.
/// The masking works on the raw bytes, so a body that is not valid UTF-8
/// keeps its length and every non-ASCII byte.
///
/// `accept-encoding` is removed from requests so that the upstream answers
/// uncompressed and the text can be inspected; otherwise a client could
/// ask for gzip and get the data unmasked. A response that is compressed
/// anyway (`content-encoding` other than `identity`) is passed through and
/// counted in `pii_mask.skipped_encoded`; alert on that metric.

///|
priv struct MaskRoot {
  mut masked : @moonproxy.Metric?
  mut skipped : @moonproxy.Metric?
}

///|
impl @moonproxy.RootContext for MaskRoot with on_plugin_start(self, _) {
  self.masked = Some(@moonproxy.Metric::counter("pii_mask.masked_responses"))
  self.skipped = Some(@moonproxy.Metric::counter("pii_mask.skipped_encoded"))
  true
}

///|
/// If masking fails, the response must not go out unmasked: reset it.
impl @moonproxy.RootContext for MaskRoot with error_policy(_) {
  FailClosed
}

///|
impl @moonproxy.RootContext for MaskRoot with new_http_context(self, _) {
  Some(MaskStream::{ root: self, active: false })
}

///|
priv struct MaskStream {
  root : MaskRoot
  mut active : Bool
}

///|
/// Text bodies only. gRPC (including `application/grpc+json`) is skipped:
/// its messages are binary length-prefixed frames, not plain text.
fn is_text(content_type : String) -> Bool {
  let ct = content_type.to_lower()
  !ct.has_prefix("application/grpc") &&
  (ct.has_prefix("text/") || ct.contains("json"))
}

///|
impl @moonproxy.HttpContext for MaskStream with on_request_headers(_, _, _) {
  @moonproxy.remove_request_header("accept-encoding")
  Continue
}

///|
impl @moonproxy.HttpContext for MaskStream with on_response_headers(self, _, _) {
  let ct = @moonproxy.get_response_header("content-type").unwrap_or("")
  if !is_text(ct) {
    return Continue
  }
  if @moonproxy.get_response_header("content-encoding") is Some(enc) &&
    enc != "identity" {
    if self.root.skipped is Some(m) {
      m.increment()
    }
    return Continue
  }
  self.active = true
  Continue
}

///|
impl @moonproxy.HttpContext for MaskStream with on_response_body(self, _, eos) {
  if !self.active {
    return Continue
  }
  if !eos {
    return Pause
  }
  self.mask()
}

///|
/// A response with trailers ends with them rather than with an
/// end-of-stream data frame; mask the buffered body here in that case.
impl @moonproxy.HttpContext for MaskStream with on_response_trailers(self, _) {
  if !self.active {
    return Continue
  }
  self.mask()
}

///|
fn MaskStream::mask(self : MaskStream) -> @moonproxy.Action raise {
  self.active = false
  let body = @moonproxy.get_response_body()
  let masked = mask_pii_bytes(body)
  if masked != body {
    @moonproxy.replace_response_body(masked)
    if self.root.masked is Some(m) {
      m.increment()
    }
  }
  Continue
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) { MaskRoot::{ masked: None, skipped: None } })
}
