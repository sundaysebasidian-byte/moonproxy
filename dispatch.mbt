///|
/// Routes host callbacks to the plugin's context objects.
///
/// The host identifies everything by integer context ids. A root context
/// (parent id 0) is created per plugin configuration; HTTP streams and TCP
/// connections are child contexts of a root. The `abi_*` functions are the
/// proxy-wasm entry points: the generated `exports.mbt` of a plugin and the
/// `proxytest` emulator call them, plugin code never does.

///|
let root_factory : Ref[((Int32) -> &RootContext)?] = { val: None, }

///|
let roots : Map[Int32, &RootContext] = Map([])

///|
/// Child context id -> its root context id. A child exists here from
/// `proxy_on_context_create`; its HTTP or TCP object is made on the first
/// callback, because only then is it known which kind of filter runs it.
let parents : Map[Int32, Int32] = Map([])

///|
let http_contexts : Map[Int32, &HttpContext] = Map([])

///|
let tcp_contexts : Map[Int32, &TcpContext] = Map([])

///|
priv struct Callout {
  owner : Int32
  /// Issued while the response was being processed (so a failure must
  /// resume or reset the response, not the request).
  response_phase : Bool
  callback : (HttpCallResponse?) -> Unit raise
}

///|
let callouts : Map[Int32, Callout] = Map([])

///|
/// Context id of the callback currently running (0 outside callbacks).
let active_context : Ref[Int32] = { val: 0, }

///|
/// True while `on_plugin_start` runs, the only time the host hands out the
/// plugin configuration.
let configuring : Ref[Bool] = { val: false, }

///|
/// Whether the running HTTP callback belongs to the response direction.
let in_response_phase : Ref[Bool] = { val: false, }

///|
/// Child contexts whose root declined to create a context of that kind
/// (`new_http_context` / `new_tcp_context` returned `None`); asked once.
let declined : Map[Int32, Bool] = Map([])

///|
fn report(id : Int32, callback : String, e : Error) -> Unit {
  log_error("moonproxy: \{callback} failed in context \{id}: \{e}")
}

///|
/// Register the plugin. Call it from `fn init` in the plugin package:
///
/// ```mbt nocheck
/// fn init {
///   @moonproxy.set_root_context(fn(_id) { MyRoot::new() })
/// }
/// ```
pub fn set_root_context(factory : (Int32) -> &RootContext) -> Unit {
  root_factory.val = Some(factory)
}

///|
/// Id of the context whose callback is running.
pub fn current_context_id() -> Int32 {
  active_context.val
}

///|
/// Forget every context. The `proxytest` emulator calls this when it starts
/// a fresh plugin instance; it is never needed inside a real proxy.
pub fn reset_contexts() -> Unit {
  roots.clear()
  parents.clear()
  http_contexts.clear()
  tcp_contexts.clear()
  callouts.clear()
  declined.clear()
  active_context.val = 0
  in_response_phase.val = false
}

///|
fn enter(id : Int32) -> Unit {
  active_context.val = id
  in_response_phase.val = false
}

///|
fn bool_to_int(b : Bool) -> Int32 {
  if b {
    1
  } else {
    0
  }
}

///|
fn policy_of(id : Int32) -> ErrorPolicy {
  let root_id = parents.get(id).unwrap_or(id)
  match roots.get(root_id) {
    Some(r) => r.error_policy()
    // Unreachable for a live stream (it is only created through its root);
    // err on the safe side.
    None => FailClosed
  }
}

///|
fn http_context(id : Int32) -> &HttpContext? {
  if http_contexts.get(id) is Some(h) {
    return Some(h)
  }
  guard parents.get(id) is Some(root_id) && roots.get(root_id) is Some(root) else {
    return None
  }
  guard !tcp_contexts.contains(id) && !declined.contains(id) else {
    return None
  }
  guard root.new_http_context(id) is Some(h) else {
    declined[id] = true
    return None
  }
  http_contexts[id] = h
  Some(h)
}

///|
fn tcp_context(id : Int32) -> &TcpContext? {
  if tcp_contexts.get(id) is Some(t) {
    return Some(t)
  }
  guard parents.get(id) is Some(root_id) && roots.get(root_id) is Some(root) else {
    return None
  }
  guard !http_contexts.contains(id) && !declined.contains(id) else {
    return None
  }
  guard root.new_tcp_context(id) is Some(t) else {
    declined[id] = true
    return None
  }
  tcp_contexts[id] = t
  Some(t)
}

// ---- root lifecycle -------------------------------------------------------

///|
pub fn abi_on_context_create(id : Int32, parent : Int32) -> Unit {
  enter(id)
  if parent == 0 {
    match root_factory.val {
      // A host may announce the same root again (e.g. on reconfiguration);
      // keep the existing object and its state.
      Some(_) if roots.contains(id) => ()
      Some(f) => roots[id] = f(id)
      None =>
        abort("moonproxy: no root context registered; call set_root_context")
    }
  } else if roots.contains(parent) {
    parents[id] = parent
  } else {
    log_error("moonproxy: unknown root context \{parent} for context \{id}")
  }
}

///|
pub fn abi_on_vm_start(id : Int32, config_size : Int32) -> Int32 {
  enter(id)
  match roots.get(id) {
    Some(r) =>
      bool_to_int(
        r.on_vm_start(config_size) catch {
          e => {
            report(id, "on_vm_start", e)
            false
          }
        },
      )
    None => 1
  }
}

///|
pub fn abi_on_configure(id : Int32, config_size : Int32) -> Int32 {
  enter(id)
  match roots.get(id) {
    Some(r) => {
      configuring.val = true
      let ok = r.on_plugin_start(config_size) catch {
        e => {
          report(id, "on_plugin_start", e)
          false
        }
      }
      configuring.val = false
      bool_to_int(ok)
    }
    None => 1
  }
}

///|
pub fn abi_on_tick(id : Int32) -> Unit {
  enter(id)
  if roots.get(id) is Some(r) {
    r.on_tick() catch {
      e => report(id, "on_tick", e)
    }
  }
}

///|
pub fn abi_on_queue_ready(id : Int32, queue_id : Int32) -> Unit {
  enter(id)
  if roots.get(id) is Some(r) {
    r.on_queue_ready(queue_id) catch {
      e => report(id, "on_queue_ready", e)
    }
  }
}

///|
/// `proxy_on_done`: a stream finished, or the host wants to shut a root
/// context down. Envoy calls it after `on_log` for HTTP streams and before
/// `on_log` for TCP connections.
pub fn abi_on_done(id : Int32) -> Int32 {
  enter(id)
  if roots.get(id) is Some(r) {
    return bool_to_int(
      r.on_plugin_done() catch {
        e => {
          report(id, "on_plugin_done", e)
          true
        }
      },
    )
  }
  if http_contexts.get(id) is Some(h) {
    h.on_done() catch {
      e => report(id, "on_done", e)
    }
  } else if tcp_contexts.get(id) is Some(t) {
    t.on_done() catch {
      e => report(id, "on_done", e)
    }
  }
  1
}

///|
pub fn abi_on_log(id : Int32) -> Unit {
  enter(id)
  if tcp_contexts.get(id) is Some(t) {
    t.on_log() catch {
      e => report(id, "on_log", e)
    }
  } else if http_context(id) is Some(h) {
    // Created here if no other callback ran (e.g. an earlier filter replied
    // directly): Envoy still logs such a request, and an access-log plugin
    // must see it.
    h.on_log() catch {
      e => report(id, "on_log", e)
    }
  }
}

///|
/// `proxy_on_delete`: the context is gone; drop everything that refers to it.
pub fn abi_on_delete(id : Int32) -> Unit {
  enter(id)
  http_contexts.remove(id)
  tcp_contexts.remove(id)
  declined.remove(id)
  parents.remove(id)
  roots.remove(id)
  let stale = []
  for token, c in callouts {
    if c.owner == id {
      stale.push(token)
    }
  }
  for token in stale {
    callouts.remove(token)
  }
}

// ---- HTTP -----------------------------------------------------------------

///|
fn http(
  id : Int32,
  callback : String,
  response : Bool,
  f : (&HttpContext) -> Action raise,
) -> Int32 {
  enter(id)
  in_response_phase.val = response
  guard http_context(id) is Some(h) else { return Continue.to_int() }
  let action = f(h) catch {
    e => {
      report(id, callback, e)
      match policy_of(id) {
        FailOpen => Continue
        FailClosed => {
          reject_http(response)
          Pause
        }
      }
    }
  }
  action.to_int()
}

///|
/// FailClosed for an HTTP stream. While the request is being processed the
/// client gets a 500. Once the upstream response has started, its headers
/// may already be on the wire, so the stream is reset instead; a reset is
/// also the fallback if the local response is refused.
fn reject_http(response : Bool) -> Unit {
  if !response {
    let sent = try
      send_http_response(
        500,
        [("content-type", "text/plain")],
        b"plugin error",
        details="moonproxy_plugin_error",
      )
    catch {
      _ => false
    } noraise {
      _ => true
    }
    if sent {
      return
    }
  }
  reset_http_stream() catch {
    _ => ()
  }
}

///|
pub fn abi_on_request_headers(
  id : Int32,
  num_headers : Int32,
  eos : Int32,
) -> Int32 {
  http(id, "on_request_headers", false, fn(h) raise {
    h.on_request_headers(num_headers, eos != 0)
  })
}

///|
pub fn abi_on_request_body(id : Int32, body_size : Int32, eos : Int32) -> Int32 {
  http(id, "on_request_body", false, fn(h) raise {
    h.on_request_body(body_size, eos != 0)
  })
}

///|
pub fn abi_on_request_trailers(id : Int32, num_trailers : Int32) -> Int32 {
  http(id, "on_request_trailers", false, fn(h) raise {
    h.on_request_trailers(num_trailers)
  })
}

///|
pub fn abi_on_response_headers(
  id : Int32,
  num_headers : Int32,
  eos : Int32,
) -> Int32 {
  http(id, "on_response_headers", true, fn(h) raise {
    h.on_response_headers(num_headers, eos != 0)
  })
}

///|
pub fn abi_on_response_body(
  id : Int32,
  body_size : Int32,
  eos : Int32,
) -> Int32 {
  http(id, "on_response_body", true, fn(h) raise {
    h.on_response_body(body_size, eos != 0)
  })
}

///|
pub fn abi_on_response_trailers(id : Int32, num_trailers : Int32) -> Int32 {
  http(id, "on_response_trailers", true, fn(h) raise {
    h.on_response_trailers(num_trailers)
  })
}

// ---- TCP ------------------------------------------------------------------

///|
fn tcp(
  id : Int32,
  callback : String,
  f : (&TcpContext) -> Action raise,
) -> Int32 {
  enter(id)
  guard tcp_context(id) is Some(t) else { return Continue.to_int() }
  let action = f(t) catch {
    e => {
      report(id, callback, e)
      match policy_of(id) {
        FailOpen => Continue
        FailClosed => {
          close_tcp()
          Pause
        }
      }
    }
  }
  action.to_int()
}

///|
fn close_tcp() -> Unit {
  close_downstream() catch {
    _ => ()
  }
  close_upstream() catch {
    _ => ()
  }
}

///|
pub fn abi_on_new_connection(id : Int32) -> Int32 {
  tcp(id, "on_new_connection", fn(t) raise { t.on_new_connection() })
}

///|
pub fn abi_on_downstream_data(id : Int32, size : Int32, eos : Int32) -> Int32 {
  tcp(id, "on_downstream_data", fn(t) raise {
    t.on_downstream_data(size, eos != 0)
  })
}

///|
pub fn abi_on_downstream_connection_close(id : Int32, peer : Int32) -> Unit {
  enter(id)
  if tcp_context(id) is Some(t) {
    t.on_downstream_close(PeerType::from_int(peer)) catch {
      e => report(id, "on_downstream_close", e)
    }
  }
}

///|
pub fn abi_on_upstream_data(id : Int32, size : Int32, eos : Int32) -> Int32 {
  tcp(id, "on_upstream_data", fn(t) raise { t.on_upstream_data(size, eos != 0) })
}

///|
pub fn abi_on_upstream_connection_close(id : Int32, peer : Int32) -> Unit {
  enter(id)
  if tcp_context(id) is Some(t) {
    t.on_upstream_close(PeerType::from_int(peer)) catch {
      e => report(id, "on_upstream_close", e)
    }
  }
}

// ---- HTTP callouts --------------------------------------------------------

///|
pub fn abi_on_http_call_response(
  root_id : Int32,
  token : Int32,
  num_headers : Int32,
  body_size : Int32,
  num_trailers : Int32,
) -> Unit {
  guard callouts.get(token) is Some(c) else { return }
  callouts.remove(token)
  let owner = c.owner
  let is_http = http_contexts.contains(owner)
  let is_tcp = tcp_contexts.contains(owner)
  if !(is_http || is_tcp || roots.contains(owner)) {
    return
  }
  // Follow-up calls (resume, send_http_response, header edits) must apply
  // to the stream that issued the callout, not to the root context. If the
  // host cannot switch, those calls would silently hit the root instead.
  if owner != root_id && host().set_effective_context(owner) != Ok {
    log_error(
      "moonproxy: context \{owner} is gone; dropping http call response",
    )
    return
  }
  enter(owner)
  in_response_phase.val = c.response_phase
  let fail = fn(what : String, e : Error) {
    report(owner, what, e)
    // The stream is paused waiting for this callback; never leave it
    // hanging until the proxy's idle timeout.
    match (policy_of(owner), is_http, is_tcp) {
      (FailOpen, true, _) => resume_http(c.response_phase)
      (FailClosed, true, _) => reject_http(c.response_phase)
      (FailOpen, _, true) => resume_downstream() catch { _ => () }
      (FailClosed, _, true) => close_tcp()
      _ => ()
    }
  }
  // `None` means the callout failed or timed out. A response that arrived
  // but cannot be read is an error, handled by the error policy.
  let response = if num_headers == 0 {
    None
  } else {
    read_http_call_response(body_size, num_trailers) catch {
      e => {
        fail("reading http call response", e)
        return
      }
    }
  }
  (c.callback)(response) catch {
    e => fail("http call callback", e)
  }
}

///|
fn resume_http(response : Bool) -> Unit {
  try {
    if response {
      resume_http_response()
    } else {
      resume_http_request()
    }
  } catch {
    _ => ()
  }
}

///|
fn register_callout(
  token : Int32,
  callback : (HttpCallResponse?) -> Unit raise,
) -> Unit {
  callouts[token] = {
    owner: active_context.val,
    response_phase: in_response_phase.val,
    callback,
  }
}

///|
/// Number of HTTP callouts waiting for a response (useful in tests).
pub fn pending_callouts() -> Int32 {
  callouts.length()
}
