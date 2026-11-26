///|
/// `@moonproxy.Host` implementation backing the emulator.

///|
fn HostEmulator::current(self : HostEmulator) -> Stream? {
  self.streams.get(self.active)
}

///|
fn access_of(s : Stream, kind : @moonproxy.MapType) -> Access {
  match kind {
    HttpRequestHeaders => s.req_headers
    HttpResponseHeaders => s.resp_headers
    HttpRequestTrailers => s.req_trailers
    HttpResponseTrailers => s.resp_trailers
    _ => Closed
  }
}

///|
/// Resolve a header map for reading or writing, applying Envoy's rules on
/// when a map is available.
fn HostEmulator::map_ref(
  self : HostEmulator,
  kind : @moonproxy.MapType,
  write : Bool,
) -> Array[(String, String)]? {
  match kind {
    HttpCallResponseHeaders | HttpCallResponseTrailers => {
      guard !write && self.callout_response is Some((h, _, t)) else {
        return None
      }
      Some(if kind == HttpCallResponseHeaders { h } else { t })
    }
    GrpcReceiveInitialMetadata | GrpcReceiveTrailingMetadata => None
    _ => {
      guard self.current() is Some(s) && s.is_http else { return None }
      match access_of(s, kind) {
        Closed => None
        ReadOnly =>
          if write {
            None
          } else {
            Some(s.maps.get(kind).unwrap_or([]))
          }
        Writable =>
          match s.maps.get(kind) {
            Some(m) => Some(m)
            None => {
              let m = []
              s.maps[kind] = m
              Some(m)
            }
          }
      }
    }
  }
}

///|
impl @moonproxy.Host for HostEmulator with log(self, level, msg) {
  self.logs.push((level, msg))
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with get_log_level(self) {
  self.log_level
}

///|
impl @moonproxy.Host for HostEmulator with get_current_time_nanos(self) {
  self.now_nanos
}

///|
/// Envoy applies the period to the root context whichever context calls it.
impl @moonproxy.Host for HostEmulator with set_tick_period_ms(self, ms) {
  self.tick_ms = ms
  Ok
}

///|
fn HostEmulator::buffer_of(
  self : HostEmulator,
  kind : @moonproxy.BufferType,
) -> Bytes? {
  match kind {
    VmConfiguration => Some(self.vm_config)
    // Envoy: only while the plugin is being configured (`temp_plugin_`).
    PluginConfiguration =>
      if self.configuring {
        Some(self.plugin_config)
      } else {
        None
      }
    HttpCallResponseBody =>
      match self.callout_response {
        Some((_, b, _)) => Some(b)
        None => None
      }
    GrpcReceiveBuffer => None
    _ =>
      match self.current() {
        Some(s) => Some(s.buffers.get(kind).unwrap_or(b""))
        None => None
      }
  }
}

///|
impl @moonproxy.Host for HostEmulator with get_buffer(self, kind, start, max) {
  guard self.buffer_of(kind) is Some(b) else { return (NotFound, b"") }
  if start < 0 || max < 0 || start > b.length() {
    return (BadArgument, b"")
  }
  let end = if max > b.length() - start { b.length() } else { start + max }
  (Ok, b[start:end].to_owned())
}

///|
/// Envoy `Buffer::copyFrom`.
impl @moonproxy.Host for HostEmulator with set_buffer(self, kind, start, size, data) {
  match kind {
    HttpRequestBody | HttpResponseBody | DownstreamData | UpstreamData => ()
    _ => return BadArgument
  }
  guard self.current() is Some(s) else { return NotFound }
  let cur = s.buffers.get(kind).unwrap_or(b"")
  if start == 0 {
    let drop = if size > cur.length() { cur.length() } else { size }
    s.buffers[kind] = concat(data, cur[drop:].to_owned())
    Ok
  } else if start >= cur.length() {
    s.buffers[kind] = concat(cur, data)
    Ok
  } else {
    BadArgument
  }
}

///|
impl @moonproxy.Host for HostEmulator with get_map_pairs(self, kind) {
  match self.map_ref(kind, false) {
    Some(m) => (Ok, @moonproxy.serialize_map(m))
    // Envoy serializes a missing map as an empty map.
    None => (Ok, @moonproxy.serialize_map([]))
  }
}

///|
impl @moonproxy.Host for HostEmulator with set_map_pairs(self, kind, data) {
  guard self.map_ref(kind, true) is Some(m) else { return BadArgument }
  let pairs = @moonproxy.deserialize_map(data) catch {
    _ => return ParseFailure
  }
  m.clear()
  m.push_iter(lower_pairs(pairs).iter())
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with get_map_value(self, kind, key) {
  guard self.map_ref(kind, false) is Some(m) else { return (BadArgument, b"") }
  let k = key.to_lower()
  for p in m {
    if p.0 == k {
      return (Ok, @utf8.encode(p.1))
    }
  }
  (NotFound, b"")
}

///|
impl @moonproxy.Host for HostEmulator with replace_map_value(self, kind, key, value) {
  guard self.map_ref(kind, true) is Some(m) else { return BadArgument }
  let k = key.to_lower()
  // Envoy setCopy: overwrite the first entry, drop the other duplicates.
  match m.search_by(fn(p) { p.0 == k }) {
    Some(i) => {
      m[i] = (k, value)
      let mut j = m.length() - 1
      while j > i {
        if m[j].0 == k {
          m.remove(j) |> ignore
        }
        j -= 1
      }
    }
    None => m.push((k, value))
  }
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with add_map_value(self, kind, key, value) {
  guard self.map_ref(kind, true) is Some(m) else { return BadArgument }
  m.push((key.to_lower(), value))
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with remove_map_value(self, kind, key) {
  guard self.map_ref(kind, true) is Some(m) else { return BadArgument }
  let k = key.to_lower()
  m.retain(fn(p) { p.0 != k })
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with get_property(self, path) {
  match self.properties.get(path_key(path)) {
    Some(v) => (Ok, v)
    None => (NotFound, b"")
  }
}

///|
impl @moonproxy.Host for HostEmulator with set_property(self, path, value) {
  self.properties[path_key(path)] = value
  Ok
}

///|
/// proxy-wasm-cpp-host `SharedData::get`.
impl @moonproxy.Host for HostEmulator with get_shared_data(self, key) {
  match self.shared.get(key) {
    Some((v, cas)) => (Ok, v, cas)
    None => (NotFound, b"", 0)
  }
}

///|
/// proxy-wasm-cpp-host `SharedData::set`: a non-zero `cas` must match the
/// stored version; every successful write takes the next global version.
impl @moonproxy.Host for HostEmulator with set_shared_data(self, key, value, cas) {
  if cas != 0 && self.cas_failures > 0 {
    // Injected race: another worker rewrote the key, so its CAS moves on.
    self.cas_failures -= 1
    self.cas_counter += 1
    if self.shared.get(key) is Some((v, _)) {
      self.shared[key] = (v, self.cas_counter)
    }
    return CasMismatch
  }
  if self.shared.get(key) is Some((_, current)) && cas != 0 && cas != current {
    return CasMismatch
  }
  self.cas_counter += 1
  self.shared[key] = (value, self.cas_counter)
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with register_shared_queue(self, name) {
  match self.queue_ids.get(name) {
    Some(id) => (Ok, id)
    None => {
      let id = self.queue_ids.length() + 1
      self.queue_ids[name] = id
      self.queues[id] = []
      (Ok, id)
    }
  }
}

///|
impl @moonproxy.Host for HostEmulator with resolve_shared_queue(self, _vm_id, name) {
  match self.queue_ids.get(name) {
    Some(id) => (Ok, id)
    None => (NotFound, 0)
  }
}

///|
impl @moonproxy.Host for HostEmulator with enqueue_shared_queue(self, id, data) {
  guard self.queues.get(id) is Some(q) else { return NotFound }
  q.push(data)
  self.ready_queues.push(id)
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with dequeue_shared_queue(self, id) {
  guard self.queues.get(id) is Some(q) else { return (NotFound, b"") }
  if q.is_empty() {
    return (Empty, b"")
  }
  (Ok, q.remove(0))
}

///|
impl @moonproxy.Host for HostEmulator with continue_stream(self, kind) {
  guard self.current() is Some(s) else { return BadArgument }
  match kind {
    Request => {
      if s.req_stop_all {
        s.req_stop_all = false
        s.replay_req = true
      }
      if s.request_paused {
        s.request_paused = false
        s.req_headers = Closed
        self.flush(s, HttpRequestBody)
      }
      s.request_resumes += 1
    }
    Response => {
      if s.resp_stop_all {
        s.resp_stop_all = false
        s.replay_resp = true
      }
      if s.response_paused {
        s.response_paused = false
        s.resp_headers = Closed
        self.flush(s, HttpResponseBody)
      }
      s.response_resumes += 1
    }
    Downstream => self.flush(s, DownstreamData)
    // Envoy implements continuing downstream data only.
    Upstream => return Unimplemented
  }
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with close_stream(self, kind) {
  guard self.current() is Some(s) else { return BadArgument }
  match kind {
    Downstream => s.closed_downstream = true
    Upstream => s.closed_upstream = true
    // Envoy `closeStream(Request|Response)` resets the HTTP stream.
    Request | Response => {
      guard s.is_http else { return BadArgument }
      s.reset = true
    }
  }
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with send_local_response(
  self,
  code,
  details,
  body,
  headers,
  _grpc
) {
  guard self.current() is Some(s) && s.is_http else { return BadArgument }
  let pairs = @moonproxy.deserialize_map(headers) catch {
    _ => return ParseFailure
  }
  s.local_pending = true
  s.local_response = Some({
    status_code: code,
    headers: lower_pairs(pairs),
    body,
    details,
  })
  Ok
}

///|
/// Envoy `Context::httpCall` argument checks.
impl @moonproxy.Host for HostEmulator with http_call(
  self,
  upstream,
  headers,
  body,
  trailers,
  timeout
) {
  if timeout < 0 || upstream == "" {
    return (BadArgument, 0)
  }
  // Envoy looks the cluster up first: an unknown name is BadArgument.
  if self.clusters.length() > 0 && !self.clusters.contains(upstream) {
    return (BadArgument, 0)
  }
  let hs = @moonproxy.deserialize_map(headers) catch {
    _ => return (ParseFailure, 0)
  }
  let ts = @moonproxy.deserialize_map(trailers) catch {
    _ => return (ParseFailure, 0)
  }
  let hs = lower_pairs(hs)
  for required in [":path", ":method", ":authority"] {
    if !hs.iter().any(fn(p) { p.0 == required }) {
      return (BadArgument, 0)
    }
  }
  let token = self.next_token
  self.next_token += 1
  self.calls[token] = {
    token,
    upstream,
    headers: hs,
    body,
    trailers: lower_pairs(ts),
    timeout_ms: timeout,
  }
  (Ok, token)
}

///|
impl @moonproxy.Host for HostEmulator with set_effective_context(self, id) {
  if id == self.root_id || self.streams.contains(id) {
    self.active = id
    Ok
  } else {
    BadArgument
  }
}

///|
impl @moonproxy.Host for HostEmulator with done(self) {
  self.done_called = true
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with define_metric(self, kind, name) {
  match self.metric_ids.get(name) {
    Some(i) => if self.metrics[i].kind == kind { (Ok, i) } else { (BadArgument, 0) }
    None => {
      let i = self.metrics.length()
      self.metrics.push({ kind, value: 0L })
      self.metric_ids[name] = i
      (Ok, i)
    }
  }
}

///|
impl @moonproxy.Host for HostEmulator with increment_metric(self, id, delta) {
  guard id >= 0 && id < self.metrics.length() else { return NotFound }
  let m = self.metrics[id]
  // Envoy `incrementMetric`: a counter needs `offset > 0`.
  if m.kind == Counter && delta <= 0L {
    return BadArgument
  }
  m.value += delta
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with record_metric(self, id, value) {
  guard id >= 0 && id < self.metrics.length() else { return NotFound }
  self.metrics[id].value = value.reinterpret_as_int64()
  Ok
}

///|
impl @moonproxy.Host for HostEmulator with get_metric(self, id) {
  guard id >= 0 && id < self.metrics.length() else { return (NotFound, 0) }
  (Ok, self.metrics[id].value.reinterpret_as_uint64())
}
