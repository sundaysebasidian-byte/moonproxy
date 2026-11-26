///|
/// TCP (L4) filter: per-connection byte accounting with a quota.
///
/// Configuration: `{"max_bytes": 1048576}` (0 or missing means no limit;
/// anything but a whole number makes the plugin fail to start).
///
/// Bytes in each direction go to the counters `tcp_quota.rx_bytes` and
/// `tcp_quota.tx_bytes`. A connection that moves more than `max_bytes`
/// in total is closed in both directions and counted in
/// `tcp_quota.closed`. When the connection ends, one access-log line
/// gives the client address and the byte totals.

///|
priv struct QuotaRoot {
  mut max_bytes : Int64
  mut rx : @moonproxy.Metric?
  mut tx : @moonproxy.Metric?
  mut closed : @moonproxy.Metric?
}

///|
impl @moonproxy.RootContext for QuotaRoot with fn on_plugin_start(self, _) {
  let text = @utf8.decode_lossy(@moonproxy.get_plugin_configuration())
  if text != "" {
    let cfg = @json.parse(text) catch {
      _ => {
        @moonproxy.log_error("tcp_quota: configuration is not valid JSON")
        return false
      }
    }
    match cfg {
      { "max_bytes": Number(n, ..), .. } if n >= 0.0 && n == n.floor() =>
        self.max_bytes = n.to_int64()
      { "max_bytes": _, .. } => {
        // A typo such as "1048576" (a string) must not silently mean
        // "no limit".
        @moonproxy.log_error("tcp_quota: max_bytes must be a whole number >= 0")
        return false
      }
      _ => ()
    }
  }
  self.rx = Some(@moonproxy.Metric::counter("tcp_quota.rx_bytes"))
  self.tx = Some(@moonproxy.Metric::counter("tcp_quota.tx_bytes"))
  self.closed = Some(@moonproxy.Metric::counter("tcp_quota.closed"))
  true
}

///|
impl @moonproxy.RootContext for QuotaRoot with fn new_tcp_context(self, _) {
  Some(Conn::{ root: self, rx: 0L, tx: 0L, cut: false, })
}

///|
priv struct Conn {
  root : QuotaRoot
  mut rx : Int64
  mut tx : Int64
  mut cut : Bool
}

///|
fn Conn::account(
  self : Conn,
  size : Int32,
  metric : @moonproxy.Metric?,
) -> @moonproxy.Action raise {
  if metric is Some(m) {
    m.increment(delta=size.to_int64())
  }
  let limit = self.root.max_bytes
  if limit > 0L && self.rx + self.tx > limit {
    self.cut = true
    if self.root.closed is Some(m) {
      m.increment()
    }
    @moonproxy.log_info(
      "tcp_quota: closing connection after \{self.rx + self.tx} bytes",
    )
    @moonproxy.close_downstream()
    @moonproxy.close_upstream()
    return Pause
  }
  Continue
}

///|
impl @moonproxy.TcpContext for Conn with fn on_downstream_data(self, size, _) {
  // After a cut, closing takes effect asynchronously: relay nothing more.
  // The host keeps the paused data and reports it again with each new
  // chunk, so it is not counted again either.
  if self.cut {
    return Pause
  }
  self.rx += size.to_int64()
  self.account(size, self.root.rx)
}

///|
impl @moonproxy.TcpContext for Conn with fn on_upstream_data(self, size, _) {
  if self.cut {
    return Pause
  }
  self.tx += size.to_int64()
  self.account(size, self.root.tx)
}

///|
impl @moonproxy.TcpContext for Conn with fn on_log(self) {
  let client = @moonproxy.get_property_string(["source", "address"]).unwrap_or(
    "-",
  )
  @moonproxy.log_info(
    "tcp_quota: client=\{client} rx=\{self.rx} tx=\{self.tx} cut=\{self.cut}",
  )
}

///|
fn init {
  @moonproxy.set_root_context(fn(_) {
    QuotaRoot::{ max_bytes: 0L, rx: None, tx: None, closed: None, }
  })
}
