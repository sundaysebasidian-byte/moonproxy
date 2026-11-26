///|
/// Masks personal data in text and JSON responses before they leave the
/// proxy (see `mask.mbt` for the rules).
///
/// The response body is buffered until end of stream so that a number
/// split across two chunks is still found; Envoy's buffer limit applies.
/// Server-sent events (`text/event-stream`, e.g. streamed LLM answers) are
/// buffered only up to the end of the last complete event (a blank line),
/// so they keep streaming event by event.
///
/// Every body is inspected except known binary types (images, audio,
/// video, fonts, archives, `application/octet-stream`, gRPC), including a
/// response without `content-type`.
/// The masking works on the raw bytes, so a body that is not valid UTF-8
/// keeps its length and every non-ASCII byte.
///
/// `accept-encoding` is removed from requests so that the upstream answers
/// uncompressed and the text can be inspected; otherwise a client could
/// ask for gzip and get the data unmasked. `range` and `if-range` are
/// removed too: with byte ranges a client could cut a number in two and
/// fetch each half unmasked. A response that is compressed
/// anyway (`content-encoding` other than `identity`) is passed through and
/// counted in `pii_mask.skipped_encoded`; alert on that metric.

///|
priv struct MaskRoot {
  mut masked : @moonproxy.Metric?
  mut skipped : @moonproxy.Metric?
}

///|
impl @moonproxy.RootContext for MaskRoot with fn on_plugin_start(self, _) {
  self.masked = Some(@moonproxy.Metric::counter("pii_mask.masked_responses"))
  self.skipped = Some(@moonproxy.Metric::counter("pii_mask.skipped_encoded"))
  true
}

///|
/// If masking fails, the response must not go out unmasked: reset it.
impl @moonproxy.RootContext for MaskRoot with fn error_policy(_) {
  FailClosed
}

///|
impl @moonproxy.RootContext for MaskRoot with fn new_http_context(self, _) {
  Some(MaskStream::{ root: self, active: false, events: false, })
}

///|
priv struct MaskStream {
  root : MaskRoot
  mut active : Bool
  mut events : Bool
}

///|
/// Everything but known binary types is inspected, so a JSON body sent
/// without a `content-type` (or as JSONP, XML, ...) is still masked. gRPC
/// (including `application/grpc+json`) is skipped: its messages are binary
/// length-prefixed frames, not plain text.
fn is_binary(content_type : String) -> Bool {
  let ct = content_type.to_lower()
  let prefixes = [
    "image/", "audio/", "video/", "font/", "application/grpc", "application/octet-stream",
    "application/zip", "application/gzip", "application/x-gzip", "application/pdf",
    "application/wasm", "application/x-protobuf", "application/protobuf",
  ]
  prefixes.iter().any(fn(p) { ct.has_prefix(p) })
}

///|
/// Index just past the last blank line (`\n\n` or `\r\n\r\n`) that ends
/// a complete server-sent event, or 0 if there is none.
fn events_end(body : Bytes) -> Int32 {
  for k = body.length() - 1; k >= 1; k = k - 1 {
    if body[k] == b'\n' &&
      (
        body[k - 1] == b'\n' ||
        (k >= 3 && body[k - 1] == b'\r' && body[k - 2] == b'\n')
      ) {
      return k + 1
    }
  }
  0
}

///|
impl @moonproxy.HttpContext for MaskStream with fn on_request_headers(_, _, _) {
  @moonproxy.remove_request_header("accept-encoding")
  @moonproxy.remove_request_header("range")
  @moonproxy.remove_request_header("if-range")
  Continue
}

///|
impl @moonproxy.HttpContext for MaskStream with fn on_response_headers(
  self,
  _,
  _,
) {
  let ct = @moonproxy.get_response_header("content-type").unwrap_or("")
  if is_binary(ct) {
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
  self.events = ct.to_lower().has_prefix("text/event-stream")
  Continue
}

///|
impl @moonproxy.HttpContext for MaskStream with fn on_response_body(
  self,
  _,
  eos,
) {
  if !self.active {
    return Continue
  }
  if !eos {
    if self.events {
      // Flush every complete event; keep buffering a partial one.
      let body = @moonproxy.get_response_body()
      if body.length() > 0 && events_end(body) == body.length() {
        self.mask_buffer(body)
        return Continue
      }
    }
    return Pause
  }
  self.mask()
}

///|
/// A response with trailers ends with them rather than with an
/// end-of-stream data frame; mask the buffered body here in that case.
impl @moonproxy.HttpContext for MaskStream with fn on_response_trailers(self, _) {
  if !self.active {
    return Continue
  }
  self.mask()
}

///|
fn MaskStream::mask(self : MaskStream) -> @moonproxy.Action raise {
  self.active = false
  self.mask_buffer(@moonproxy.get_response_body())
  Continue
}

///|
fn MaskStream::mask_buffer(self : MaskStream, body : Bytes) -> Unit raise {
  let masked = mask_pii_bytes(body)
  if masked != body {
    @moonproxy.replace_response_body(masked)
    if self.root.masked is Some(m) {
      m.increment()
    }
  }
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) {
    MaskRoot::{ masked: None, skipped: None, }
  })
}
