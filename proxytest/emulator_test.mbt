///|
/// Tests of the SDK dispatcher + API against the emulator. Each test
/// registers its own tiny plugin.

///|
struct Root {
  on_http : (Int32) -> &@moonproxy.HttpContext
  policy : @moonproxy.ErrorPolicy
}

///|
impl @moonproxy.RootContext for Root with fn new_http_context(self, id) {
  Some((self.on_http)(id))
}

///|
impl @moonproxy.RootContext for Root with fn error_policy(self) {
  self.policy
}

///|
fn install(
  on_http : (Int32) -> &@moonproxy.HttpContext,
  policy~ : @moonproxy.ErrorPolicy = FailOpen,
  clusters~ : Array[String] = [],
) -> @proxytest.HostEmulator {
  @moonproxy.set_root_context(fn(_) { Root::{ on_http, policy, } })
  let emu = @proxytest.HostEmulator::new(clusters~)
  guard emu.start() else { abort("plugin failed to start") }
  emu
}

///|
/// A filter defined by closures, to keep each test self-contained.
struct Fn {
  req_headers : () -> @moonproxy.Action raise
  req_body : (Int32, Bool) -> @moonproxy.Action raise
  resp_headers : () -> @moonproxy.Action raise
  done : () -> Unit raise
  log : () -> Unit raise
}

///|
fn Fn::new(
  req_headers~ : () -> @moonproxy.Action raise = () => Continue,
  req_body~ : (Int32, Bool) -> @moonproxy.Action raise = (_, _) => Continue,
  resp_headers~ : () -> @moonproxy.Action raise = () => Continue,
  done~ : () -> Unit raise = () => (),
  log~ : () -> Unit raise = () => (),
) -> Fn {
  { req_headers, req_body, resp_headers, done, log, }
}

///|
impl @moonproxy.HttpContext for Fn with fn on_response_headers(self, _, _) {
  (self.resp_headers)()
}

///|
impl @moonproxy.HttpContext for Fn with fn on_done(self) {
  (self.done)()
}

///|
impl @moonproxy.HttpContext for Fn with fn on_request_headers(self, _, _) {
  (self.req_headers)()
}

///|
impl @moonproxy.HttpContext for Fn with fn on_request_body(self, n, eos) {
  (self.req_body)(n, eos)
}

///|
impl @moonproxy.HttpContext for Fn with fn on_log(self) {
  (self.log)()
}

///|
test "header edits are lower-cased and visible to the host" {
  let emu = install(fn(_) {
    Fn::new(req_headers=fn() raise {
      @moonproxy.add_request_header("X-Added", "1")
      @moonproxy.replace_request_header("user-agent", "moonproxy")
      @moonproxy.remove_request_header("x-secret")
      Continue
    })
  })
  let id = emu.init_http()
  let a = emu.call_on_request_headers(id, [
    (":path", "/"),
    ("User-Agent", "curl"),
    ("x-secret", "a"),
    ("X-Secret", "b"),
  ])
  inspect(a, content="Continue")
  debug_inspect(
    emu.request_headers(id),
    content=(
      #|[(":path", "/"), ("user-agent", "moonproxy"), ("x-added", "1")]
    ),
  )
}

///|
test "get_header returns the first of repeated values, like Envoy" {
  let seen = Ref(None)
  let emu = install(fn(_) {
    Fn::new(req_headers=fn() raise {
      seen.val = @moonproxy.get_request_header("X-A")
      Continue
    })
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [("x-a", "1"), ("x-a", "2")])
  debug_inspect(seen.val, content="Some(\"1\")")
}

///|
test "headers are not writable after the header phase continued" {
  let emu = install(fn(_) {
    Fn::new(req_body=fn(_, _) raise {
      @moonproxy.add_request_header("x-late", "1")
      Continue
    })
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [(":path", "/")])
  let _ = emu.call_on_request_body(id, b"hi")
  debug_inspect(
    emu.logs(level=Error),
    content=(
      #|["moonproxy: on_request_body failed in context 2: add_header: BadArgument"]
    ),
  )
}

///|
test "log phase can read headers but not change them" {
  let got = Ref([])
  let emu = install(fn(_) {
    Fn::new(log=fn() raise {
      got.val = @moonproxy.get_request_headers()
      @moonproxy.add_request_header("x", "y")
    })
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [(":path", "/a")])
  emu.complete_stream(id)
  debug_inspect(got.val, content="[(\":path\", \"/a\")]")
  debug_inspect(
    emu.logs(level=Error),
    content=(
      #|["moonproxy: on_log failed in context 2: add_header: BadArgument"]
    ),
  )
}

///|
test "paused body accumulates chunks until the plugin continues" {
  let sizes = []
  let emu = install(fn(_) {
    Fn::new(req_body=fn(n, eos) raise {
      sizes.push(n)
      if !eos {
        return Pause
      }
      let body = @moonproxy.get_request_body()
      @moonproxy.replace_request_body(
        @utf8.encode(@utf8.decode_lossy(body).to_upper()),
      )
      Continue
    })
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [(":path", "/")])
  inspect(
    emu.call_on_request_body(id, b"ab", end_of_stream=false),
    content="Pause",
  )
  inspect(
    emu.call_on_request_body(id, b"cd", end_of_stream=false),
    content="Pause",
  )
  inspect(emu.call_on_request_body(id, b"ef"), content="Continue")
  debug_inspect(sizes, content="[2, 4, 6]")
  inspect(emu.request_body(id), content="b\"ABCDEF\"")
}

///|
test "buffer edits follow Envoy copyFrom" {
  let emu = install(fn(_) {
    Fn::new(req_body=fn(_, _) raise {
      @moonproxy.prepend_request_body(b"<")
      @moonproxy.append_request_body(b">")
      // A start inside the buffer is rejected by Envoy.
      @moonproxy.set_buffer(HttpRequestBody, 1, 1, b"x")
      Continue
    })
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [(":path", "/")])
  let _ = emu.call_on_request_body(id, b"body")
  inspect(emu.request_body(id), content="b\"<body>\"")
  debug_inspect(
    emu.logs(level=Error),
    content=(
      #|["moonproxy: on_request_body failed in context 2: set_buffer: BadArgument"]
    ),
  )
}

///|
test "local response" {
  let emu = install(fn(_) {
    Fn::new(req_headers=fn() raise {
      @moonproxy.send_http_response(
        403,
        [("Content-Type", "text/plain")],
        b"denied",
        details="blocked",
      )
      Pause
    })
  })
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, [(":path", "/")]), content="Pause")
  debug_inspect(
    emu.local_response(id),
    content=(
      #|Some(
      #|  {
      #|    status_code: 403,
      #|    headers: [("content-type", "text/plain")],
      #|    body: <Bytes: [0x64, 0x65, 0x6e, 0x69, 0x65, 0x64]>,
      #|    details: "blocked",
      #|  },
      #|)
    ),
  )
}

///|
test "callout: pause, answer, resume the issuing stream" {
  let emu = install(fn(_) {
    Fn::new(req_headers=fn() raise {
      let _ = @moonproxy.dispatch_http_call(
        "authz",
        [(":method", "GET"), (":path", "/check"), (":authority", "authz")],
        timeout_ms=500,
        fn(answer) raise {
          guard answer is Some(r) else { fail("expected an answer") }
          @moonproxy.replace_request_header(
            "x-authz",
            "\{r.headers.length()}:\{r.status_code}:\{@utf8.decode_lossy(r.body)}",
          )
          @moonproxy.resume_http_request()
        },
      )
      Pause
    })
  })
  let a = emu.init_http()
  let b = emu.init_http()
  inspect(emu.call_on_request_headers(a, [(":path", "/a")]), content="Pause")
  inspect(emu.call_on_request_headers(b, [(":path", "/b")]), content="Pause")
  let calls = emu.http_calls()
  inspect(calls.length(), content="2")
  inspect(calls[0].upstream, content="authz")
  inspect(@moonproxy.pending_callouts(), content="2")
  // Answer the second stream's call first: the right stream must resume.
  emu.call_on_http_call_response(calls[1].token, [(":status", "200")], b"ok")
  inspect(emu.request_resumes(a), content="0")
  inspect(emu.request_resumes(b), content="1")
  inspect(emu.is_request_paused(b), content="false")
  debug_inspect(
    emu.request_headers(b),
    content=(
      #|[(":path", "/b"), ("x-authz", "1:200:ok")]
    ),
  )
  // A stream that went away never sees its callout callback.
  emu.complete_stream(a)
  inspect(@moonproxy.pending_callouts(), content="0")
}

///|
test "callout without required pseudo headers is rejected" {
  let emu = install(fn(_) {
    Fn::new(req_headers=fn() raise {
      let _ = @moonproxy.dispatch_http_call(
        "authz",
        [(":path", "/")],
        timeout_ms=100,
        fn(_) {  },
      )
      Continue
    })
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [(":path", "/")])
  debug_inspect(
    emu.logs(level=Error),
    content=(
      #|["moonproxy: on_request_headers failed in context 2: dispatch_http_call: BadArgument"]
    ),
  )
}

///|
test "shared data CAS" {
  let _ = @proxytest.HostEmulator::new()
  inspect(@moonproxy.get_shared_data("k") is None, content="true")
  @moonproxy.set_shared_data("k", b"1")
  guard @moonproxy.get_shared_data("k") is Some((v, cas)) else {
    fail("missing")
  }
  inspect(v, content="b\"1\"")
  @moonproxy.set_shared_data("k", b"2", cas~)
  // The old version is now stale.
  try @moonproxy.set_shared_data("k", b"3", cas~) catch {
    e => inspect(e, content="set_shared_data: CasMismatch")
  } noraise {
    _ => fail("stale CAS must fail")
  }
  guard @moonproxy.get_shared_data("k") is Some((v2, _)) else {
    fail("missing")
  }
  inspect(v2, content="b\"2\"")
}

///|
test "metrics" {
  let emu = @proxytest.HostEmulator::new()
  let c = @moonproxy.Metric::counter("requests_total")
  c.increment()
  c.increment(delta=4L)
  debug_inspect(emu.metric("requests_total"), content="Some(5)")
  try c.increment(delta=-1L) catch {
    e => inspect(e, content="increment_metric: BadArgument")
  } noraise {
    _ => fail("counters cannot go down")
  }
  let g = @moonproxy.Metric::gauge("inflight")
  g.record(7)
  inspect(g.value(), content="7")
  // Re-defining with the same name returns the same metric.
  inspect(@moonproxy.Metric::counter("requests_total").value(), content="5")
}

///|
test "queues and properties" {
  let emu = @proxytest.HostEmulator::new()
  let q = @moonproxy.register_shared_queue("events")
  inspect(@moonproxy.resolve_shared_queue("", "events") == q, content="true")
  inspect(@moonproxy.dequeue_shared_queue(q) is None, content="true")
  @moonproxy.enqueue_shared_queue(q, b"a")
  @moonproxy.enqueue_shared_queue(q, b"b")
  inspect(@moonproxy.dequeue_shared_queue(q).unwrap(), content="b\"a\"")
  emu.set_property(["source", "address"], b"10.0.0.1:5000")
  debug_inspect(
    @moonproxy.get_property_string(["source", "address"]),
    content="Some(\"10.0.0.1:5000\")",
  )
  debug_inspect(@moonproxy.get_property(["nope"]), content="None")
}

///|
struct CfgRoot {
  seen : Ref[String]
}

///|
impl @moonproxy.RootContext for CfgRoot with fn on_plugin_start(self, size) {
  let cfg = @moonproxy.get_plugin_configuration() catch { _ => return false }
  self.seen.val = "\{size}:\{@utf8.decode_lossy(cfg)}"
  cfg != b"reject"
}

///|
test "configuration is visible to on_plugin_start" {
  let seen = Ref("")
  @moonproxy.set_root_context(fn(_) { CfgRoot::{ seen, } })
  inspect(
    @proxytest.HostEmulator::new(plugin_config=b"{\"a\":1}").start(),
    content="true",
  )
  inspect(seen.val, content="7:{\"a\":1}")
  inspect(
    @proxytest.HostEmulator::new(plugin_config=b"reject").start(),
    content="false",
  )
}

///|
test "Pause on headers holds body and trailers until the plugin resumes" {
  let seen : Array[String] = []
  let emu = install(
    fn(_) {
      Fn::new(
        req_headers=fn() raise {
          let req = [(":method", "GET"), (":path", "/"), (":authority", "svc")]
          let _ = @moonproxy.dispatch_http_call("svc", req, fn(_) raise {
            @moonproxy.resume_http_request()
          })
          Pause
        },
        req_body=fn(size, eos) {
          seen.push("body \{size} \{eos}")
          Continue
        },
      )
    },
    clusters=["svc"],
  )
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, []), content="Pause")
  // Envoy's StopAllIterationAndWatermark: the plugin does not see these yet.
  inspect(
    emu.call_on_request_body(id, b"abc", end_of_stream=false),
    content="Pause",
  )
  inspect(
    emu.call_on_request_body(id, b"de", end_of_stream=false),
    content="Pause",
  )
  inspect(emu.call_on_request_trailers(id, [("t", "1")]), content="Pause")
  inspect(seen.length(), content="0")
  inspect(emu.forwarded_request_body(id).length(), content="0")
  guard emu.http_calls() is [call] else { fail("one callout") }
  emu.call_on_http_call_response(call.token, [(":status", "200")], b"")
  // Resumed: the buffered data arrives as one chunk, then the trailers.
  debug_inspect(seen, content="[\"body 5 false\"]")
  inspect(@utf8.decode_lossy(emu.forwarded_request_body(id)), content="abcde")
  inspect(emu.is_request_paused(id), content="false")
}

///|
test "FailOpen logs the error and lets the request through" {
  let emu = install(fn(_) { Fn::new(req_headers=fn() raise { fail("boom") }) })
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, []), content="Continue")
  inspect(emu.local_response(id) is None, content="true")
  inspect(emu.logs(level=Error).length(), content="1")
}

///|
test "FailClosed rejects the request when a header callback raises" {
  let emu = install(
    fn(_) { Fn::new(req_headers=fn() raise { fail("boom") }) },
    policy=FailClosed,
  )
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, []), content="Pause")
  guard emu.local_response(id) is Some(r) else { fail("expected a 500") }
  inspect(r.status_code, content="500")
  inspect(r.details, content="moonproxy_plugin_error")
}

///|
test "FailClosed rejects the request when a body callback raises" {
  let emu = install(
    fn(_) { Fn::new(req_body=fn(_, _) raise { fail("bad body") }) },
    policy=FailClosed,
  )
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [])
  inspect(emu.call_on_request_body(id, b"x"), content="Pause")
  debug_inspect(
    emu.local_response(id).map(fn(r) { r.status_code }),
    content="Some(500)",
  )
  inspect(emu.forwarded_request_body(id).length(), content="0")
}

///|
fn failing_callout() -> Fn {
  Fn::new(req_headers=fn() raise {
    let _ = @moonproxy.dispatch_http_call(
      "authz",
      [(":method", "GET"), (":path", "/"), (":authority", "authz")],
      fn(_) raise { fail("callback bug") },
    )
    Pause
  })
}

///|
test "a raising callout callback never leaves the stream hanging" {
  let closed = install(fn(_) { failing_callout() }, policy=FailClosed)
  let id = closed.init_http()
  let _ = closed.call_on_request_headers(id, [])
  closed.call_on_http_call_response(
    closed.http_calls()[0].token,
    [(":status", "200")],
    b"",
  )
  debug_inspect(
    closed.local_response(id).map(fn(r) { r.status_code }),
    content="Some(500)",
  )
  inspect(closed.request_resumes(id), content="0")
  let open = install(fn(_) { failing_callout() }, policy=FailOpen)
  let id2 = open.init_http()
  let _ = open.call_on_request_headers(id2, [])
  open.call_on_http_call_response(
    open.http_calls()[0].token,
    [(":status", "200")],
    b"",
  )
  inspect(open.request_resumes(id2), content="1")
  inspect(open.local_response(id2) is None, content="true")
}

///|
test "a timed out callout reaches the callback as None" {
  let got = Ref("")
  let emu = install(fn(_) {
    Fn::new(req_headers=fn() raise {
      let _ = @moonproxy.dispatch_http_call(
        "authz",
        [(":method", "GET"), (":path", "/"), (":authority", "authz")],
        fn(answer) { got.val = if answer is None { "none" } else { "some" } },
      )
      Pause
    })
  })
  let _ = emu.call_on_request_headers(emu.init_http(), [])
  emu.call_on_http_call_response(emu.http_calls()[0].token, [], b"")
  inspect(got.val, content="none")
}

///|
test "callouts to an unknown cluster fail like in Envoy" {
  let emu = install(fn(_) { failing_callout() }, clusters=["other"])
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, []), content="Continue")
  inspect(emu.http_calls().length(), content="0")
  inspect(
    emu.logs(level=Error)[0].contains("dispatch_http_call: BadArgument"),
    content="true",
  )
}

///|
test "a local response runs through the plugin's own response callbacks" {
  let emu = install(fn(_) {
    Fn::new(
      req_headers=fn() raise {
        @moonproxy.send_http_response(
          403,
          [("content-type", "text/plain")],
          b"denied",
        )
        Pause
      },
      resp_headers=fn() raise {
        // Runs for the local reply too, as in Envoy.
        @moonproxy.add_response_header("x-seen-by-plugin", "1")
        Continue
      },
    )
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [])
  guard emu.local_response(id) is Some(r) else { fail("no local response") }
  inspect(r.status_code, content="403")
  debug_inspect(
    r.headers,
    content=(
      #|[("content-type", "text/plain"), ("x-seen-by-plugin", "1")]
    ),
  )
  inspect(@utf8.decode_lossy(r.body), content="denied")
}

///|
test "an HTTP stream ends with log, then done, as in Envoy" {
  let order = []
  let emu = install(fn(_) {
    Fn::new(
      done=fn() {
        // Context::onDestroy runs after the filter chain is torn down.
        let h = @moonproxy.get_request_header(":path") catch {
          e => Some(e.to_string())
        }
        order.push("done \{opt(h)}")
      },
      log=fn() raise {
        order.push("log \{opt(@moonproxy.get_request_header(":path"))}")
      },
    )
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [(":path", "/a")])
  emu.complete_stream(id)
  debug_inspect(
    order,
    content=(
      #|["log Some(/a)", "done Some(get_header: BadArgument)"]
    ),
  )
}

///|
test "a request no callback saw is still logged" {
  let order = []
  let emu = install(fn(_) { Fn::new(log=fn() { order.push("log") }) })
  // E.g. an earlier filter replied directly: only on_log reaches the plugin.
  let id = emu.init_http()
  emu.complete_stream(id)
  debug_inspect(order, content="[\"log\"]")
}

///|
struct BothRoot {
  kinds : Array[String]
}

///|
struct Tcp {
  kinds : Array[String]
}

///|
impl @moonproxy.TcpContext for Tcp with fn on_new_connection(self) {
  self.kinds.push("tcp")
  Continue
}

///|
impl @moonproxy.TcpContext for Tcp with fn on_downstream_data(_, _, _) {
  fail("tcp bug")
}

///|
impl @moonproxy.RootContext for BothRoot with fn new_http_context(self, _) {
  self.kinds.push("http")
  Some(Fn::new())
}

///|
impl @moonproxy.RootContext for BothRoot with fn new_tcp_context(self, _) {
  Some(Tcp::{ kinds: self.kinds, })
}

///|
impl @moonproxy.RootContext for BothRoot with fn error_policy(_) {
  FailClosed
}

///|
test "a root with both HTTP and TCP filters gets the right kind per stream" {
  let kinds = []
  @moonproxy.set_root_context(fn(_) { BothRoot::{ kinds, } })
  let emu = @proxytest.HostEmulator::new()
  guard emu.start() else { fail("start") }
  let conn = emu.init_tcp()
  inspect(emu.call_on_new_connection(conn), content="Continue")
  let stream = emu.init_http()
  let _ = emu.call_on_request_headers(stream, [])
  debug_inspect(
    kinds,
    content=(
      #|["tcp", "http"]
    ),
  )
  // FailClosed on TCP closes both sides of the connection.
  inspect(emu.call_on_downstream_data(conn, b"x"), content="Pause")
  inspect(emu.downstream_closed(conn), content="true")
  inspect(emu.upstream_closed(conn), content="true")
}

///|
fn raising_response_callout() -> &@moonproxy.HttpContext {
  Fn::new(resp_headers=fn() raise {
    let req = [(":method", "GET"), (":path", "/"), (":authority", "svc")]
    let _ = @moonproxy.dispatch_http_call("svc", req, fn(_) raise {
      fail("broken callback")
    })
    Pause
  })
}

///|
test "a callout from the response phase fails in the response direction" {
  let open = install(fn(_) { raising_response_callout() }, clusters=["svc"])
  let id = open.init_http()
  let _ = open.call_on_request_headers(id, [])
  inspect(
    open.call_on_response_headers(id, [(":status", "200")]),
    content="Pause",
  )
  open.call_on_http_call_response(
    open.http_calls()[0].token,
    [(":status", "200")],
    b"",
  )
  inspect(open.response_resumes(id), content="1")
  inspect(open.request_resumes(id), content="0")
  let closed = install(
    fn(_) { raising_response_callout() },
    policy=FailClosed,
    clusters=["svc"],
  )
  let id = closed.init_http()
  let _ = closed.call_on_request_headers(id, [])
  let _ = closed.call_on_response_headers(id, [(":status", "200")])
  closed.call_on_http_call_response(
    closed.http_calls()[0].token,
    [(":status", "200")],
    b"",
  )
  // Response headers may already be on their way: reset, no local 500.
  inspect(closed.was_reset(id), content="true")
  inspect(closed.local_response(id) is None, content="true")
}

///|
test "FailClosed in a response callback resets the stream" {
  let emu = install(
    fn(_) { Fn::new(resp_headers=fn() raise { fail("boom") }) },
    policy=FailClosed,
  )
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [])
  inspect(
    emu.call_on_response_headers(id, [(":status", "200")]),
    content="Pause",
  )
  inspect(emu.was_reset(id), content="true")
  inspect(emu.local_response(id) is None, content="true")
}

///|
test "a root that declines a stream is asked only once" {
  let asked = Ref(0)
  @moonproxy.set_root_context(fn(_) { Declining::{ asked, } })
  let emu = @proxytest.HostEmulator::new()
  guard emu.start() else { abort("start") }
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [])
  let _ = emu.call_on_request_body(id, b"x")
  let _ = emu.call_on_response_headers(id, [])
  inspect(asked.val, content="1")
}

///|
struct Declining {
  asked : Ref[Int32]
}

///|
impl @moonproxy.RootContext for Declining with fn new_http_context(self, _) {
  self.asked.val += 1
  None
}

///|
test "the plugin configuration is only served during on_plugin_start" {
  let seen = Ref("")
  let emu = install(fn(_) {
    Fn::new(req_headers=fn() {
      let _ = @moonproxy.get_plugin_configuration() catch {
        e => {
          seen.val = e.to_string()
          b""
        }
      }
      Continue
    })
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [])
  inspect(seen.val, content="get_plugin_configuration: NotFound")
}

///|
fn opt(o : String?) -> String {
  match o {
    Some(s) => "Some(\{s})"
    None => "None"
  }
}

///|
test "request data after a local response reaches neither the plugin nor the upstream" {
  let bodies = Ref(0)
  let emu = install(fn(_) {
    Fn::new(
      req_headers=fn() {
        @moonproxy.send_http_response(403, [], b"no") catch {
          _ => ()
        }
        Pause
      },
      req_body=fn(_, _) {
        bodies.val += 1
        Continue
      },
    )
  })
  let id = emu.init_http()
  let _ = emu.call_on_request_headers(id, [(":path", "/")])
  inspect(emu.local_response(id).map(fn(r) { r.status_code }) is Some(403), content="true")
  debug_inspect(emu.call_on_request_body(id, b"secret"), content="Pause")
  debug_inspect(emu.call_on_request_trailers(id, [("x", "1")]), content="Pause")
  inspect(bodies.val, content="0")
  inspect(emu.forwarded_request_body(id).length(), content="0")
}
