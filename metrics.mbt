///|
/// A host metric (exported by Envoy as a stat).
pub struct Metric {
  id : Int32
  kind : MetricType
}

///|
/// Define (or look up) a metric. Define metrics once, e.g. in
/// `on_plugin_start`, and keep the handle.
pub fn Metric::new(kind : MetricType, name : String) -> Metric raise HostError {
  let (st, id) = host().define_metric(kind, name)
  check("define_metric", st)
  { id, kind, }
}

///|
pub fn Metric::counter(name : String) -> Metric raise HostError {
  Metric::new(Counter, name)
}

///|
pub fn Metric::gauge(name : String) -> Metric raise HostError {
  Metric::new(Gauge, name)
}

///|
pub fn Metric::histogram(name : String) -> Metric raise HostError {
  Metric::new(Histogram, name)
}

///|
/// Add `delta` (counters only accept non-negative deltas). A zero delta is
/// skipped here: Envoy answers `BadArgument` to a zero counter increment.
pub fn Metric::increment(
  self : Metric,
  delta~ : Int64 = 1L,
) -> Unit raise HostError {
  if delta == 0L {
    return
  }
  check("increment_metric", host().increment_metric(self.id, delta))
}

///|
/// Set a gauge or record a histogram sample.
pub fn Metric::record(self : Metric, value : UInt64) -> Unit raise HostError {
  check("record_metric", host().record_metric(self.id, value))
}

///|
pub fn Metric::value(self : Metric) -> UInt64 raise HostError {
  let (st, v) = host().get_metric(self.id)
  check("get_metric", st)
  v
}

///|
pub fn Metric::kind(self : Metric) -> MetricType {
  self.kind
}
