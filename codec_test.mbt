///|
test "map round trip" {
  let pairs = [(":path", "/a?b=1"), ("x-name", "值"), ("empty", "")]
  let bytes = @moonproxy.serialize_map(pairs)
  inspect(bytes.length(), content="59")
  assert_eq(@moonproxy.deserialize_map(bytes), pairs)
}

///|
test "map wire layout matches spec" {
  let bytes = @moonproxy.serialize_map([("a", "bc")])
  inspect(
    bytes,
    content=(
      #|b"\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00a\x00bc\x00"
    ),
  )
}

///|
test "empty map" {
  inspect(@moonproxy.serialize_map([]).length(), content="4")
  assert_eq(@moonproxy.deserialize_map(b""), [])
  assert_eq(@moonproxy.deserialize_map(b"\x00\x00\x00\x00"), [])
}

///|
test "malformed map is rejected" {
  let bad = [
    b"\x01\x00", b"\xff\xff\xff\x7f", b"\x01\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00ab",
  ]
  for b in bad {
    try @moonproxy.deserialize_map(b) catch {
      HostError(_, status) => inspect(status, content="ParseFailure")
    } noraise {
      _ => fail("expected a parse failure")
    }
  }
}

///|
test "property path" {
  inspect(
    @moonproxy.serialize_path(["request", "path"]),
    content=(
      #|b"request\x00path"
    ),
  )
}
