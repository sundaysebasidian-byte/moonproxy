///|
/// Token-bucket rate limiting shared by all Envoy worker threads.
///
/// Configuration:
/// ```json
/// {"rate_per_second": 10, "burst": 20, "key_header": "x-client-id", "buckets": 4096}
/// ```
///
/// Clients are told apart by their source IP address, or, when `key_header`
/// is set, by that request header. Only use `key_header` for a header that
/// an earlier filter sets or overwrites (an authenticated user or tenant
/// id): a header the client controls lets it pick a fresh key, and so a
/// full bucket, on every request.
///
/// The client key is hashed (FNV-1a) into one of `buckets` token buckets
/// kept in proxy-wasm shared data. Shared data never expires, so this fixed
/// number is what bounds the memory used whatever clients send; two clients
/// whose keys collide share one bucket and are limited together (stricter,
/// never looser). Every worker VM updates a bucket with a compare-and-swap
/// loop, so concurrent requests on different threads cannot spend the same
/// token twice. The very first write of a bucket cannot be conditional
/// (proxy-wasm CAS 0 always succeeds), so a brand-new bucket may hand out up
/// to one extra token per worker, once.
///
/// Over-limit requests get 429 and a `retry-after` header.

///|
priv struct Limits {
  rate : Int64 // tokens per second
  burst : Int64
  key_header : String? // None: source IP address
  buckets : Int
}

///|
priv struct LimitRoot {
  mut limits : Limits
  mut allowed : @moonproxy.Metric?
  mut limited : @moonproxy.Metric?
}

///|
const MILLI : Int64 = 1000L

///|
const MAX_CAS_RETRIES : Int = 16

///|
const DEFAULT_BUCKETS : Int = 4096

///|
/// Upper bound for `rate_per_second` and `burst`: `burst * 1000 * 1e6`
/// (milli-tokens times nanoseconds) must stay inside an Int64.
const MAX_LIMIT : Int64 = 1_000_000_000L

///|
/// FNV-1a, 32 bits: cheap, stable across workers and restarts.
fn fnv1a(s : String) -> UInt {
  let mut h : UInt = 2166136261U
  for b in @utf8.encode(s) {
    h = (h ^ b.to_uint()) * 16777619U
  }
  h
}

///|
/// Shared-data key of the bucket that `client` falls into.
fn bucket_key(limits : Limits, client : String) -> String {
  "rate_limit:" + (fnv1a(client) % limits.buckets.reinterpret_as_uint()).to_string()
}

///|
/// `1.2.3.4:5678` -> `1.2.3.4`, `[::1]:5678` -> `::1`.
fn strip_port(addr : String) -> String {
  if addr.has_prefix("[") {
    match addr.find("]") {
      Some(i) => return addr[1:i].to_owned()
      None => return addr
    }
  }
  let parts = addr.split(":").collect()
  if parts is [host, _] {
    host.to_owned()
  } else {
    addr
  }
}

///|
fn json_int(v : Json) -> Int64? {
  match v {
    Number(n, ..) if n >= 0.0 && n == n.floor() => Some(n.to_int64())
    _ => None
  }
}

///|
impl @moonproxy.RootContext for LimitRoot with on_plugin_start(self, _) {
  let cfg = @json.parse(
    @utf8.decode_lossy(@moonproxy.get_plugin_configuration()),
  )
  guard cfg is { "rate_per_second": rate, .. } && json_int(rate) is Some(r) && r > 0L && r <= MAX_LIMIT else {
    @moonproxy.log_error("rate_limit: rate_per_second must be 1..1000000000")
    return false
  }
  let burst = match cfg {
    { "burst": b, .. } =>
      match json_int(b) {
        // Bounded so that milli-token arithmetic cannot overflow.
        Some(b) if b > 0L && b <= MAX_LIMIT => b
        _ => {
          @moonproxy.log_error("rate_limit: burst must be 1..1000000000")
          return false
        }
      }
    _ => r
  }
  let key_header = match cfg {
    { "key_header": String(h), .. } if h != "" => Some(h.to_lower())
    _ => None
  }
  let buckets = match cfg {
    { "buckets": n, .. } =>
      match json_int(n) {
        Some(n) if n >= 1L && n <= 1_000_000L => n.to_int()
        _ => {
          @moonproxy.log_error("rate_limit: buckets must be 1..1000000")
          return false
        }
      }
    _ => DEFAULT_BUCKETS
  }
  self.limits = { rate: r, burst, key_header, buckets }
  self.allowed = Some(@moonproxy.Metric::counter("rate_limit.allowed"))
  self.limited = Some(@moonproxy.Metric::counter("rate_limit.limited"))
  true
}

///|
impl @moonproxy.RootContext for LimitRoot with new_http_context(self, _) {
  Some(LimitStream::{ root: self })
}

///|
priv struct LimitStream {
  root : LimitRoot
}

///|
/// Bucket state: milli-tokens left and the time they were computed.
/// Stored as text `"<milli_tokens>:<nanos>"` so it is easy to inspect.
priv struct Bucket {
  milli_tokens : Int64
  at_nanos : Int64
}

///|
fn Bucket::parse(b : Bytes) -> Bucket? {
  let s = @utf8.decode_lossy(b)
  let parts = s.split(":").collect()
  guard parts is [t, n] else { return None }
  let tokens = @strconv.parse_int64(t.to_owned()) catch { _ => return None }
  let nanos = @strconv.parse_int64(n.to_owned()) catch { _ => return None }
  Some({ milli_tokens: tokens, at_nanos: nanos })
}

///|
fn Bucket::encode(self : Bucket) -> Bytes {
  @utf8.encode("\{self.milli_tokens}:\{self.at_nanos}")
}

///|
/// Refill a bucket to `now` and try to take one token.
/// Returns the new bucket and, when limited, the seconds until a token.
///
/// `rate` tokens per second is `rate / 1e6` milli-tokens per nanosecond.
/// Only the time actually turned into milli-tokens is consumed from the
/// clock (`at_nanos` advances by that much), so requests that arrive faster
/// than one milli-token apart still add up instead of being rounded away.
fn take(limits : Limits, prev : Bucket?, now : Int64) -> (Bucket, Int?) {
  let cap = limits.burst * MILLI
  let (current, at) = match prev {
    None => (cap, now)
    Some(b) => {
      let elapsed = if now > b.at_nanos { now - b.at_nanos } else { 0L }
      // Time to refill an empty bucket; beyond it the bucket is full. This
      // also keeps `elapsed * rate` far from overflowing.
      let fill_ns = cap * 1_000_000L / limits.rate
      if elapsed >= fill_ns {
        (cap, now)
      } else {
        let refill = elapsed * limits.rate / 1_000_000L
        let t = b.milli_tokens + refill
        if t >= cap {
          (cap, now)
        } else {
          (t, b.at_nanos + refill * 1_000_000L / limits.rate)
        }
      }
    }
  }
  if current >= MILLI {
    ({ milli_tokens: current - MILLI, at_nanos: at }, None)
  } else {
    let missing = MILLI - current
    let wait_ms = (missing + limits.rate - 1L) / limits.rate
    let wait_s = ((wait_ms + 999L) / 1000L).to_int()
    ({ milli_tokens: current, at_nanos: at }, Some(if wait_s < 1 { 1 } else { wait_s }))
  }
}

///|
/// Run `take` against shared data with optimistic concurrency.
fn acquire(limits : Limits, client : String) -> Int? raise {
  let key = bucket_key(limits, client)
  for attempt = 0; attempt < MAX_CAS_RETRIES; attempt = attempt + 1 {
    let now = @moonproxy.current_time_nanos()
    let (prev, cas) = match @moonproxy.get_shared_data(key) {
      Some((data, cas)) => (Bucket::parse(data), cas)
      None => (None, 0)
    }
    let (next, retry_after) = take(limits, prev, now)
    @moonproxy.set_shared_data(key, next.encode(), cas~) catch {
      @moonproxy.HostError(_, CasMismatch) => continue
      e => raise e
    }
    return retry_after
  }
  // Heavy contention: fail open for this request rather than stall it.
  @moonproxy.log_warn("rate_limit: CAS retries exhausted for \{client}")
  None
}

///|
impl @moonproxy.HttpContext for LimitStream with on_request_headers(self, _, _) {
  let root = self.root
  let client = match root.limits.key_header {
    Some(h) => "h:" + @moonproxy.get_request_header(h).unwrap_or("")
    None =>
      "ip:" +
      strip_port(
        @moonproxy.get_property_string(["source", "address"]).unwrap_or(""),
      )
  }
  match acquire(root.limits, client) {
    None => {
      if root.allowed is Some(m) {
        m.increment()
      }
      Continue
    }
    Some(seconds) => {
      if root.limited is Some(m) {
        m.increment()
      }
      @moonproxy.send_http_response(
        429,
        [("retry-after", seconds.to_string()), ("content-type", "text/plain")],
        b"rate limited\n",
        details="rate_limited",
      )
      Pause
    }
  }
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) {
    LimitRoot::{
      limits: { rate: 1L, burst: 1L, key_header: None, buckets: DEFAULT_BUCKETS },
      allowed: None,
      limited: None,
    }
  })
}
