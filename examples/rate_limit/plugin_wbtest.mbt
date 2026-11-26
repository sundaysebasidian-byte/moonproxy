///|
test "refill never exceeds the burst" {
  let limits = { rate: 5L, burst: 2L, key_header: None, buckets: 16, seed: "", }
  let (b, _) = take(
    limits,
    Some({ milli_tokens: 0L, at_nanos: 0L, }),
    3_600_000_000_000L,
  )
  inspect(b.milli_tokens, content="1000")
}

///|
test "requests closer than a millisecond still refill the bucket" {
  // 10 tokens/s, burst 1: one token every 100 ms. Requests arrive every
  // 0.5 ms for one second; about 10 of them must get through, not 1.
  let limits = {
    rate: 10L,
    burst: 1L,
    key_header: None,
    buckets: 16,
    seed: "",
  }
  let mut bucket : Bucket? = None
  let mut allowed = 0
  for i in 0..<2000 {
    let now = i.to_int64() * 500_000L
    let (b, wait) = take(limits, bucket, now)
    bucket = Some(b)
    if wait is None {
      allowed += 1
    }
  }
  // The first request takes the initial token, then one per 100 ms.
  inspect(allowed, content="10")
}

///|
test "a very old bucket comes back full without overflow" {
  let limits = {
    rate: 1_000_000L,
    burst: 3L,
    key_header: None,
    buckets: 16,
    seed: "",
  }
  let (b, wait) = take(
    limits,
    Some({ milli_tokens: 0L, at_nanos: 0L, }),
    9_000_000_000_000_000_000L,
  )
  inspect(wait is None, content="true")
  inspect(b.milli_tokens, content="2000")
}

///|
test "source addresses lose their port" {
  inspect(strip_port("10.0.0.7:51234"), content="10.0.0.7")
  inspect(strip_port("[2001:db8::1]:443"), content="2001:db8::1")
  inspect(strip_port("2001:db8::1"), content="2001:db8::1")
}

///|
test "any number of client keys maps onto the configured buckets" {
  let limits = { rate: 1L, burst: 1L, key_header: None, buckets: 8, seed: "", }
  let keys = Map([])
  for i in 0..<1000 {
    keys[bucket_key(limits, "client-\{i}")] = true
  }
  inspect(keys.length() <= 8, content="true")
}

///|
test "bucket numbers parse up to the Int64 limit" {
  debug_inspect(
    decimal("1764121000123456789"),
    content="Some(1764121000123456789)",
  )
  debug_inspect(
    decimal("9223372036854775807"),
    content="Some(9223372036854775807)",
  )
  debug_inspect(decimal("9223372036854775808"), content="None")
  debug_inspect(decimal("-1"), content="None")
  debug_inspect(decimal(""), content="None")
}

///|
test "IPv6 clients are grouped by /64" {
  inspect(
    client_of_address("[2001:db8:1:2:aaaa::1]:443"),
    content="2001:db8:1:2::/64",
  )
  inspect(
    client_of_address("[2001:db8:1:2:ffff:1:2:3]:80"),
    content="2001:db8:1:2::/64",
  )
  inspect(client_of_address("[2001:0db8::7]:80"), content="2001:db8:0:0::/64")
  inspect(client_of_address("[::ffff:10.0.0.7]:80"), content="10.0.0.7")
  inspect(client_of_address("10.0.0.7:51234"), content="10.0.0.7")
}

///|
test "the hash seed moves clients between buckets" {
  let a = {
    rate: 1L,
    burst: 1L,
    key_header: None,
    buckets: 1 << 20,
    seed: "a",
  }
  let b = { ..a, seed: "b", }
  let mut moved = 0
  for i in 0..<100 {
    if bucket_key(a, "client-\{i}") != bucket_key(b, "client-\{i}") {
      moved += 1
    }
  }
  inspect(moved > 90, content="true")
}
