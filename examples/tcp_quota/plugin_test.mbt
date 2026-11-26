///|
fn setup(cfg : String) -> @proxytest.HostEmulator {
  let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(cfg))
  guard emu.start() else { abort("start") }
  emu.set_property(["source", "address"], b"10.0.0.7:51234")
  emu
}

///|
test "bytes are counted per direction and logged at the end" {
  let emu = setup("{}")
  let id = emu.init_tcp()
  let _ = emu.call_on_new_connection(id)
  let _ = emu.call_on_downstream_data(id, b"PING\r\n")
  let _ = emu.call_on_upstream_data(id, b"+PONG\r\n")
  inspect(emu.upstream_data(id).length(), content="7")
  emu.call_on_downstream_close(id)
  emu.complete_stream(id)
  debug_inspect(emu.metric("tcp_quota.rx_bytes"), content="Some(6)")
  debug_inspect(emu.metric("tcp_quota.tx_bytes"), content="Some(7)")
  debug_inspect(
    emu.logs(level=Info),
    content=(
      #|["tcp_quota: client=10.0.0.7:51234 rx=6 tx=7 cut=false"]
    ),
  )
}

///|
test "a connection over its quota is closed both ways" {
  let emu = setup("{\"max_bytes\":10}")
  let id = emu.init_tcp()
  let _ = emu.call_on_new_connection(id)
  inspect(emu.call_on_downstream_data(id, b"12345678"), content="Continue")
  inspect(emu.call_on_upstream_data(id, b"abcd"), content="Pause")
  inspect(emu.downstream_closed(id), content="true")
  inspect(emu.upstream_closed(id), content="true")
  debug_inspect(emu.metric("tcp_quota.closed"), content="Some(1)")
  // Data that arrives before the close lands is held, and not counted again.
  inspect(emu.call_on_upstream_data(id, b"ef"), content="Pause")
  debug_inspect(emu.metric("tcp_quota.tx_bytes"), content="Some(4)")
}

///|
test "invalid configuration stops the plugin" {
  for
    cfg in [
      "{max_bytes", "{\"max_bytes\":\"1048576\"}", "{\"max_bytes\":-1}", "{\"max_bytes\":1.5}",
    ] {
    let emu = @proxytest.HostEmulator::new(plugin_config=@utf8.encode(cfg))
    inspect(emu.start(), content="false")
  }
}
