///|
/// Token-bucket rate limiting shared by all Envoy worker threads.
///
/// Configuration:
/// ```json
/// {"rate_per_second": 10, "burst": 20, "key_header": "x-client-id", "buckets": 4096,
///  "hash_seed": "<random secret>"}
/// ```
///
/// Clients are told apart by their source IP address, or, when `key_header`
/// is set, by that request header. Only use `key_header` for a header that
/// an earlier filter sets or overwrites (an authenticated user or tenant
/// id): a header the client controls lets it pick a fresh key, and so a
/// full bucket, on every request.
///
/// IPv6 clients are grouped by /64, the block a single host or customer is
/// usually given, so rotating addresses inside it does not buy fresh
/// buckets.
///
/// The client key is hashed (FNV-1a, seeded) into one of `buckets` token
/// buckets kept in proxy-wasm shared data. Shared data never expires, so
/// this fixed number is what bounds the memory used whatever clients send;
/// two clients whose keys collide share one bucket and are limited
/// together. The seed keeps a client from choosing a key that lands in a
/// victim's bucket: set `hash_seed` to a secret, or a seed is drawn from the
/// clock when the plugin starts and shared by all workers through shared
/// data (each worker re-reads it on its first request, after every worker
/// has started). FNV-1a is not a cryptographic hash, so the seed makes
/// collisions hard to aim, not impossible to find by probing. Every worker VM updates a bucket with a compare-and-swap
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
  buckets : Int32
  seed : String
}

///|
priv struct LimitRoot {
  mut limits : Limits
  mut seed_confirmed : Bool
  mut allowed : @moonproxy.Metric?
  mut limited : @moonproxy.Metric?
}

///|
const MILLI : Int64 = 1000L

///|
const MAX_CAS_RETRIES : Int32 = 16

///|
const DEFAULT_BUCKETS : Int32 = 4096

///|
/// Upper bound for `rate_per_second` and `burst`: `burst * 1000 * 1e6`
/// (milli-tokens times nanoseconds) must stay inside an Int64.
const MAX_LIMIT : Int64 = 1_000_000_000L

///|
/// FNV-1a, 32 bits, over `seed` then `s`: cheap and the same in every
/// worker that has the same seed.
fn fnv1a(seed : String, s : String) -> UInt32 {
  let mut h : UInt32 = 2166136261U
  for b in @utf8.encode(seed) {
    h = (h ^ b.to_uint()) * 16777619U
  }
  h = (h ^ 0xffU) * 16777619U
  for b in @utf8.encode(s) {
    h = (h ^ b.to_uint()) * 16777619U
  }
  h
}

///|
/// Shared-data key of the bucket that `client` falls into.
fn bucket_key(limits : Limits, client : String) -> String {
  "rate_limit:" +
  (fnv1a(limits.seed, client) % limits.buckets.reinterpret_as_uint()).to_string()
}

///|
const SEED_KEY : String = "rate_limit.seed"

///|
/// The seed shared by all workers: the stored one, or a new one from the
/// clock if none is stored yet. Two workers starting at the same moment
/// may both write; whichever write landed last is what both read back on
/// their first request.
fn shared_seed() -> String raise {
  if @moonproxy.get_shared_data(SEED_KEY) is Some((data, _)) {
    return @utf8.decode_lossy(data)
  }
  let seed = @moonproxy.current_time_nanos().to_string()
  @moonproxy.set_shared_data(SEED_KEY, @utf8.encode(seed))
  seed
}

///|
/// Expand an IPv6 address to its 8 groups, or None if it is not one.
fn ipv6_groups(addr : String) -> Array[String]? {
  let halves = addr.split("::").map(fn(h) { h.to_owned() }).collect()
  let part = fn(h : String) -> Array[String] {
    if h == "" {
      []
    } else {
      h.split(":").map(fn(g) { g.to_owned() }).collect()
    }
  }
  let groups = match halves {
    [all] => part(all)
    [head, tail] => {
      let h = part(head)
      let t = part(tail)
      if h.length() + t.length() > 7 {
        return None
      }
      let all = h.copy()
      for _ in 0..<(8 - h.length() - t.length()) {
        all.push("0")
      }
      for g in t {
        all.push(g)
      }
      all
    }
    _ => return None
  }
  if groups.length() == 8 {
    Some(groups)
  } else {
    None
  }
}

///|
/// Rate-limit key of a source address: IPv4 as is, IPv6 by its /64
/// (IPv4-mapped IPv6 as the IPv4 address).
fn client_of_address(addr : String) -> String {
  let host = strip_port(addr)
  if !host.contains(":") {
    return host
  }
  if host.contains(".") {
    // ::ffff:1.2.3.4
    let parts = host.split(":").collect()
    return parts[parts.length() - 1].to_owned()
  }
  match ipv6_groups(host.to_lower()) {
    Some(g) => {
      let norm : Array[String] = []
      for k in 0..<4 {
        let cs = g[k].to_array()
        let mut i = 0
        while i < cs.length() - 1 && cs[i] == '0' {
          i += 1
        }
        let sb = StringBuilder()
        for j in i..<cs.length() {
          sb.write_char(cs[j])
        }
        norm.push(sb.to_string())
      }
      norm.join(":") + "::/64"
    }
    None => host
  }
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
impl @moonproxy.RootContext for LimitRoot with fn on_plugin_start(self, _) {
  let cfg = @json.parse(
    @utf8.decode_lossy(@moonproxy.get_plugin_configuration()),
  )
  guard cfg is { "rate_per_second": rate, .. } &&
    json_int(rate) is Some(r) &&
    r > 0L &&
    r <= MAX_LIMIT else {
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
  let (seed, confirmed) = match cfg {
    { "hash_seed": String(h), .. } if h != "" => (h, true)
    _ => (shared_seed(), false)
  }
  self.limits = { rate: r, burst, key_header, buckets, seed, }
  self.seed_confirmed = confirmed
  self.allowed = Some(@moonproxy.Metric::counter("rate_limit.allowed"))
  self.limited = Some(@moonproxy.Metric::counter("rate_limit.limited"))
  true
}

///|
impl @moonproxy.RootContext for LimitRoot with fn new_http_context(self, _) {
  Some(LimitStream::{ root: self, })
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
  guard decimal(t) is Some(tokens) && decimal(n) is Some(nanos) else {
    return None
  }
  Some({ milli_tokens: tokens, at_nanos: nanos, })
}

///|
/// Non-negative decimal integer that fits an Int64 (timestamps in
/// nanoseconds have 19 digits).
fn decimal(s : StringView) -> Int64? {
  if s.length() == 0 {
    return None
  }
  let max = 9223372036854775807L
  let mut v = 0L
  for c in s {
    guard c >= '0' && c <= '9' else { return None }
    let d = (c.to_int() - '0'.to_int()).to_int64()
    if v > (max - d) / 10L {
      return None
    }
    v = v * 10L + d
  }
  Some(v)
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
fn take(limits : Limits, prev : Bucket?, now : Int64) -> (Bucket, Int32?) {
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
    ({ milli_tokens: current - MILLI, at_nanos: at, }, None)
  } else {
    let missing = MILLI - current
    let wait_ms = (missing + limits.rate - 1L) / limits.rate
    let wait_s = ((wait_ms + 999L) / 1000L).to_int()
    (
      { milli_tokens: current, at_nanos: at, },
      Some(if wait_s < 1 { 1 } else { wait_s }),
    )
  }
}

///|
/// Run `take` against shared data with optimistic concurrency.
fn acquire(limits : Limits, client : String) -> Int32? raise {
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
impl @moonproxy.HttpContext for LimitStream with fn on_request_headers(
  self,
  _,
  _,
) {
  let root = self.root
  if !root.seed_confirmed {
    root.seed_confirmed = true
    root.limits = { ..root.limits, seed: shared_seed(), }
  }
  let client = match root.limits.key_header {
    Some(h) => "h:" + @moonproxy.get_request_header(h).unwrap_or("")
    None =>
      "ip:" +
      client_of_address(
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
      limits: {
        rate: 1L,
        burst: 1L,
        key_header: None,
        buckets: DEFAULT_BUCKETS,
        seed: "",
      },
      seed_confirmed: true,
      allowed: None,
      limited: None,
    }
  })
}
