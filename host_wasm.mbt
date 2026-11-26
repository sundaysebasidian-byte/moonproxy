///|
/// Real proxy-wasm host: `env.proxy_*` imports of ABI v0.2.1.
///
/// Memory protocol: data we pass to the host lives in MoonBit-owned byte
/// arrays whose payload address is handed over directly. Data the host
/// returns is written into memory obtained from `proxy_on_memory_allocate`
/// (`memory_allocate` below) and then adopted as a `Bytes` without copying.

///|
fn proxy_log(level : Int, ptr : Int, len : Int) -> Int = "env" "proxy_log"

///|
fn proxy_get_log_level(ret : Int) -> Int = "env" "proxy_get_log_level"

///|
fn proxy_get_current_time_nanoseconds(ret : Int) -> Int = "env" "proxy_get_current_time_nanoseconds"

///|
fn proxy_set_tick_period_milliseconds(ms : Int) -> Int = "env" "proxy_set_tick_period_milliseconds"

///|
fn proxy_get_buffer_bytes(
  kind : Int,
  start : Int,
  max : Int,
  ret_ptr : Int,
  ret_len : Int,
) -> Int = "env" "proxy_get_buffer_bytes"

///|
fn proxy_set_buffer_bytes(
  kind : Int,
  start : Int,
  size : Int,
  ptr : Int,
  len : Int,
) -> Int = "env" "proxy_set_buffer_bytes"

///|
fn proxy_get_header_map_pairs(kind : Int, ret_ptr : Int, ret_len : Int) -> Int = "env" "proxy_get_header_map_pairs"

///|
fn proxy_set_header_map_pairs(kind : Int, ptr : Int, len : Int) -> Int = "env" "proxy_set_header_map_pairs"

///|
fn proxy_get_header_map_value(
  kind : Int,
  kptr : Int,
  klen : Int,
  ret_ptr : Int,
  ret_len : Int,
) -> Int = "env" "proxy_get_header_map_value"

///|
fn proxy_replace_header_map_value(
  kind : Int,
  kptr : Int,
  klen : Int,
  vptr : Int,
  vlen : Int,
) -> Int = "env" "proxy_replace_header_map_value"

///|
fn proxy_add_header_map_value(
  kind : Int,
  kptr : Int,
  klen : Int,
  vptr : Int,
  vlen : Int,
) -> Int = "env" "proxy_add_header_map_value"

///|
fn proxy_remove_header_map_value(kind : Int, kptr : Int, klen : Int) -> Int = "env" "proxy_remove_header_map_value"

///|
fn proxy_get_property(
  pptr : Int,
  plen : Int,
  ret_ptr : Int,
  ret_len : Int,
) -> Int = "env" "proxy_get_property"

///|
fn proxy_set_property(pptr : Int, plen : Int, vptr : Int, vlen : Int) -> Int = "env" "proxy_set_property"

///|
fn proxy_get_shared_data(
  kptr : Int,
  klen : Int,
  ret_ptr : Int,
  ret_len : Int,
  ret_cas : Int,
) -> Int = "env" "proxy_get_shared_data"

///|
fn proxy_set_shared_data(
  kptr : Int,
  klen : Int,
  vptr : Int,
  vlen : Int,
  cas : Int,
) -> Int = "env" "proxy_set_shared_data"

///|
fn proxy_register_shared_queue(nptr : Int, nlen : Int, ret_id : Int) -> Int = "env" "proxy_register_shared_queue"

///|
fn proxy_resolve_shared_queue(
  vptr : Int,
  vlen : Int,
  nptr : Int,
  nlen : Int,
  ret_id : Int,
) -> Int = "env" "proxy_resolve_shared_queue"

///|
fn proxy_enqueue_shared_queue(id : Int, ptr : Int, len : Int) -> Int = "env" "proxy_enqueue_shared_queue"

///|
fn proxy_dequeue_shared_queue(id : Int, ret_ptr : Int, ret_len : Int) -> Int = "env" "proxy_dequeue_shared_queue"

///|
fn proxy_continue_stream(kind : Int) -> Int = "env" "proxy_continue_stream"

///|
fn proxy_close_stream(kind : Int) -> Int = "env" "proxy_close_stream"

///|
fn proxy_send_local_response(
  code : Int,
  dptr : Int,
  dlen : Int,
  bptr : Int,
  blen : Int,
  hptr : Int,
  hlen : Int,
  grpc : Int,
) -> Int = "env" "proxy_send_local_response"

///|
fn proxy_http_call(
  uptr : Int,
  ulen : Int,
  hptr : Int,
  hlen : Int,
  bptr : Int,
  blen : Int,
  tptr : Int,
  tlen : Int,
  timeout : Int,
  ret_token : Int,
) -> Int = "env" "proxy_http_call"

///|
fn proxy_set_effective_context(id : Int) -> Int = "env" "proxy_set_effective_context"

///|
fn proxy_done() -> Int = "env" "proxy_done"

///|
fn proxy_define_metric(kind : Int, nptr : Int, nlen : Int, ret_id : Int) -> Int = "env" "proxy_define_metric"

///|
fn proxy_increment_metric(id : Int, delta : Int64) -> Int = "env" "proxy_increment_metric"

///|
fn proxy_record_metric(id : Int, value : UInt64) -> Int = "env" "proxy_record_metric"

///|
fn proxy_get_metric(id : Int, ret : Int) -> Int = "env" "proxy_get_metric"

// ---- raw memory helpers -------------------------------------------------

// These helpers follow the MoonBit FFI of wit-bindgen
// (crates/moonbit/src/ffi/ffi.mbt): `$moonbit.gc.malloc` + `init_array8`
// gives a reference-counted byte block whose payload address is what the
// host sees, and `decref` releases it. Compile-time constants (`b"..."`)
// are static objects that `decref` leaves alone, so borrowing them through
// `with_bytes` is safe. Like the reference, `mem_malloc` asks for 4 bytes
// more than needed (a trailing byte keeps the payload of an empty block
// addressable). The host only writes out-parameters on `Ok`; the slots are
// zeroed first anyway, so a host that returns early never leaves garbage
// to be read as a pointer.

///|
extern "wasm" fn mem_malloc(size : Int) -> Int =
  #|(func (param i32) (result i32) (local i32)
  #| local.get 0 i32.const 4 i32.add call $moonbit.gc.malloc
  #| local.tee 1 i32.const 0 call $moonbit.init_array8
  #| local.get 1)

///|
extern "wasm" fn mem_free(ptr : Int) =
  #|(func (param i32) local.get 0 call $moonbit.decref)

///|
#owned(bytes)
extern "wasm" fn bytes_ptr(bytes : Bytes) -> Int =
  #|(func (param i32) (result i32) local.get 0)

///|
extern "wasm" fn adopt_bytes(ptr : Int, len : Int) -> Bytes =
  #|(func (param i32) (param i32) (result i32) (local i32)
  #| local.get 0 local.tee 2
  #| local.get 1 call $moonbit.init_array8
  #| local.get 2)

///|
extern "wasm" fn load32(ptr : Int) -> Int =
  #|(func (param i32) (result i32) local.get 0 i32.load)

///|
extern "wasm" fn store32(ptr : Int, value : Int) =
  #|(func (param i32) (param i32) local.get 0 local.get 1 i32.store)

///|
extern "wasm" fn load64(ptr : Int) -> Int64 =
  #|(func (param i32) (result i64) local.get 0 i64.load)

///|
/// Entry point for `proxy_on_memory_allocate`.
pub fn memory_allocate(size : Int) -> Int {
  mem_malloc(size)
}

///|
/// Scratch area for host out-parameters (two pointers + a u32/u64).
priv struct Ret {
  ptr : Int
}

///|
fn Ret::new() -> Ret {
  let ptr = mem_malloc(16)
  for i in 0..<4 {
    store32(ptr + i * 4, 0)
  }
  { ptr, }
}

///|
fn Ret::slot(self : Ret, i : Int) -> Int {
  self.ptr + i * 4
}

///|
/// Adopt the (data, len) pair the host wrote into slots 0 and 1.
fn Ret::take_bytes(self : Ret) -> Bytes {
  let data = load32(self.ptr)
  let len = load32(self.ptr + 4)
  if data == 0 {
    b""
  } else {
    adopt_bytes(data, len)
  }
}

///|
fn Ret::free(self : Ret) -> Unit {
  mem_free(self.ptr)
}

///|
priv struct FfiHost {}

///|
fn default_host() -> &Host {
  FfiHost::{  }
}

///|
/// Call `f(ptr, len)` with a borrowed view of `b`.
fn[T] with_bytes(b : Bytes, f : (Int, Int) -> T) -> T {
  let len = b.length()
  let p = bytes_ptr(b)
  let r = f(p, len)
  mem_free(p)
  r
}

///|
fn[T] with_str(s : String, f : (Int, Int) -> T) -> T {
  with_bytes(@utf8.encode(s), f)
}

///|
fn get_with(call : (Ret) -> Int) -> (Status, Bytes) {
  let ret = Ret::new()
  let st = Status::from_int(call(ret))
  let data = if st == Ok { ret.take_bytes() } else { b"" }
  ret.free()
  (st, data)
}

///|
impl Host for FfiHost with log(_, level, msg) {
  Status::from_int(with_str(msg, fn(p, l) { proxy_log(level.to_int(), p, l) }))
}

///|
impl Host for FfiHost with get_log_level(_) {
  let ret = Ret::new()
  let st = proxy_get_log_level(ret.ptr)
  let level = if st == 0 { load32(ret.ptr) } else { 0 }
  ret.free()
  LogLevel::from_int(level)
}

///|
impl Host for FfiHost with get_current_time_nanos(_) {
  let ret = Ret::new()
  let _ = proxy_get_current_time_nanoseconds(ret.ptr)
  let t = load64(ret.ptr)
  ret.free()
  t
}

///|
impl Host for FfiHost with set_tick_period_ms(_, ms) {
  Status::from_int(proxy_set_tick_period_milliseconds(ms))
}

///|
impl Host for FfiHost with get_buffer(_, kind, start, max) {
  get_with(fn(ret) {
    proxy_get_buffer_bytes(kind.to_int(), start, max, ret.slot(0), ret.slot(1))
  })
}

///|
impl Host for FfiHost with set_buffer(_, kind, start, size, data) {
  Status::from_int(
    with_bytes(data, fn(p, l) {
      proxy_set_buffer_bytes(kind.to_int(), start, size, p, l)
    }),
  )
}

///|
impl Host for FfiHost with get_map_pairs(_, kind) {
  get_with(fn(ret) {
    proxy_get_header_map_pairs(kind.to_int(), ret.slot(0), ret.slot(1))
  })
}

///|
impl Host for FfiHost with set_map_pairs(_, kind, data) {
  Status::from_int(
    with_bytes(data, fn(p, l) { proxy_set_header_map_pairs(kind.to_int(), p, l) }),
  )
}

///|
impl Host for FfiHost with get_map_value(_, kind, key) {
  with_str(key, fn(kp, kl) {
    get_with(fn(ret) {
      proxy_get_header_map_value(kind.to_int(), kp, kl, ret.slot(0), ret.slot(1))
    })
  })
}

///|
impl Host for FfiHost with replace_map_value(_, kind, key, value) {
  Status::from_int(
    with_str(key, fn(kp, kl) {
      with_str(value, fn(vp, vl) {
        proxy_replace_header_map_value(kind.to_int(), kp, kl, vp, vl)
      })
    }),
  )
}

///|
impl Host for FfiHost with add_map_value(_, kind, key, value) {
  Status::from_int(
    with_str(key, fn(kp, kl) {
      with_str(value, fn(vp, vl) {
        proxy_add_header_map_value(kind.to_int(), kp, kl, vp, vl)
      })
    }),
  )
}

///|
impl Host for FfiHost with remove_map_value(_, kind, key) {
  Status::from_int(
    with_str(key, fn(kp, kl) { proxy_remove_header_map_value(kind.to_int(), kp, kl) }),
  )
}

///|
impl Host for FfiHost with get_property(_, path) {
  with_bytes(path, fn(pp, pl) {
    get_with(fn(ret) { proxy_get_property(pp, pl, ret.slot(0), ret.slot(1)) })
  })
}

///|
impl Host for FfiHost with set_property(_, path, value) {
  Status::from_int(
    with_bytes(path, fn(pp, pl) {
      with_bytes(value, fn(vp, vl) { proxy_set_property(pp, pl, vp, vl) })
    }),
  )
}

///|
impl Host for FfiHost with get_shared_data(_, key) {
  with_str(key, fn(kp, kl) {
    let ret = Ret::new()
    let st = Status::from_int(
      proxy_get_shared_data(kp, kl, ret.slot(0), ret.slot(1), ret.slot(2)),
    )
    let (data, cas) = if st == Ok {
      (ret.take_bytes(), load32(ret.slot(2)))
    } else {
      (b"", 0)
    }
    ret.free()
    (st, data, cas)
  })
}

///|
impl Host for FfiHost with set_shared_data(_, key, value, cas) {
  Status::from_int(
    with_str(key, fn(kp, kl) {
      with_bytes(value, fn(vp, vl) { proxy_set_shared_data(kp, kl, vp, vl, cas) })
    }),
  )
}

///|
fn get_id(call : (Int) -> Int) -> (Status, Int) {
  let ret = Ret::new()
  let st = Status::from_int(call(ret.ptr))
  let id = if st == Ok { load32(ret.ptr) } else { 0 }
  ret.free()
  (st, id)
}

///|
impl Host for FfiHost with register_shared_queue(_, name) {
  with_str(name, fn(np, nl) {
    get_id(fn(r) { proxy_register_shared_queue(np, nl, r) })
  })
}

///|
impl Host for FfiHost with resolve_shared_queue(_, vm_id, name) {
  with_str(vm_id, fn(vp, vl) {
    with_str(name, fn(np, nl) {
      get_id(fn(r) { proxy_resolve_shared_queue(vp, vl, np, nl, r) })
    })
  })
}

///|
impl Host for FfiHost with enqueue_shared_queue(_, id, data) {
  Status::from_int(
    with_bytes(data, fn(p, l) { proxy_enqueue_shared_queue(id, p, l) }),
  )
}

///|
impl Host for FfiHost with dequeue_shared_queue(_, id) {
  get_with(fn(ret) { proxy_dequeue_shared_queue(id, ret.slot(0), ret.slot(1)) })
}

///|
impl Host for FfiHost with continue_stream(_, kind) {
  Status::from_int(proxy_continue_stream(kind.to_int()))
}

///|
impl Host for FfiHost with close_stream(_, kind) {
  Status::from_int(proxy_close_stream(kind.to_int()))
}

///|
impl Host for FfiHost with send_local_response(_, code, details, body, headers, grpc) {
  Status::from_int(
    with_str(details, fn(dp, dl) {
      with_bytes(body, fn(bp, bl) {
        with_bytes(headers, fn(hp, hl) {
          proxy_send_local_response(code, dp, dl, bp, bl, hp, hl, grpc)
        })
      })
    }),
  )
}

///|
impl Host for FfiHost with http_call(_, upstream, headers, body, trailers, timeout) {
  with_str(upstream, fn(up, ul) {
    with_bytes(headers, fn(hp, hl) {
      with_bytes(body, fn(bp, bl) {
        with_bytes(trailers, fn(tp, tl) {
          get_id(fn(r) {
            proxy_http_call(up, ul, hp, hl, bp, bl, tp, tl, timeout, r)
          })
        })
      })
    })
  })
}

///|
impl Host for FfiHost with set_effective_context(_, id) {
  Status::from_int(proxy_set_effective_context(id))
}

///|
impl Host for FfiHost with done(_) {
  Status::from_int(proxy_done())
}

///|
impl Host for FfiHost with define_metric(_, kind, name) {
  with_str(name, fn(np, nl) {
    get_id(fn(r) { proxy_define_metric(kind.to_int(), np, nl, r) })
  })
}

///|
impl Host for FfiHost with increment_metric(_, id, delta) {
  Status::from_int(proxy_increment_metric(id, delta))
}

///|
impl Host for FfiHost with record_metric(_, id, value) {
  Status::from_int(proxy_record_metric(id, value))
}

///|
impl Host for FfiHost with get_metric(_, id) {
  let ret = Ret::new()
  let st = Status::from_int(proxy_get_metric(id, ret.ptr))
  let v = if st == Ok { load64(ret.ptr).reinterpret_as_uint64() } else { 0 }
  ret.free()
  (st, v)
}
