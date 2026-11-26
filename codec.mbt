///|
/// Header map / property path codecs used on the proxy-wasm wire.
///
/// A serialized map is: `u32 count`, then `count` pairs of
/// `(u32 key_len, u32 value_len)`, then for every pair `key \0 value \0`.
/// All integers are little-endian.

///|
fn write_u32_le(buf : FixedArray[Byte], at : Int32, v : Int32) -> Unit {
  buf[at] = (v & 0xff).to_byte()
  buf[at + 1] = ((v >> 8) & 0xff).to_byte()
  buf[at + 2] = ((v >> 16) & 0xff).to_byte()
  buf[at + 3] = ((v >> 24) & 0xff).to_byte()
}

///|
fn read_u32_le(buf : Bytes, at : Int32) -> Int32 {
  buf[at].to_int() |
  (buf[at + 1].to_int() << 8) |
  (buf[at + 2].to_int() << 16) |
  (buf[at + 3].to_int() << 24)
}

///|
/// Serialize header pairs into the proxy-wasm map wire format.
pub fn serialize_map(pairs : Array[(String, String)]) -> Bytes {
  let encoded = pairs.map(fn(p) { (@utf8.encode(p.0), @utf8.encode(p.1)) })
  let mut size = 4 + pairs.length() * 8
  for p in encoded {
    size += p.0.length() + p.1.length() + 2
  }
  let buf = FixedArray::make(size, b'\x00')
  write_u32_le(buf, 0, pairs.length())
  let mut data = 4 + pairs.length() * 8
  for i, p in encoded {
    let (k, v) = p
    write_u32_le(buf, 4 + i * 8, k.length())
    write_u32_le(buf, 8 + i * 8, v.length())
    buf.blit_from_bytes(data, k, 0, k.length())
    data += k.length() + 1
    buf.blit_from_bytes(data, v, 0, v.length())
    data += v.length() + 1
  }
  Bytes::from_array(buf)
}

///|
/// Parse the proxy-wasm map wire format. Malformed input raises
/// `HostError(_, ParseFailure)` instead of reading out of bounds.
pub fn deserialize_map(
  bytes : Bytes,
) -> Array[(String, String)] raise HostError {
  let out = []
  if bytes.length() == 0 {
    return out
  }
  if bytes.length() < 4 {
    raise HostError("map: truncated header", ParseFailure)
  }
  let n = read_u32_le(bytes, 0)
  if n < 0 || n > (bytes.length() - 4) / 8 {
    raise HostError("map: bad pair count \{n}", ParseFailure)
  }
  let mut p = 4 + n * 8
  for i in 0..<n {
    let klen = read_u32_le(bytes, 4 + i * 8)
    let vlen = read_u32_le(bytes, 8 + i * 8)
    if klen < 0 ||
      vlen < 0 ||
      klen > bytes.length() - p - 1 ||
      vlen > bytes.length() - p - klen - 2 {
      raise HostError("map: pair \{i} out of bounds", ParseFailure)
    }
    let k = @utf8.decode_lossy(bytes[p:p + klen])
    p += klen + 1
    let v = @utf8.decode_lossy(bytes[p:p + vlen])
    p += vlen + 1
    out.push((k, v))
  }
  out
}

///|
/// Join property path segments with NUL, e.g. `["request", "path"]`.
pub fn serialize_path(path : Array[String]) -> Bytes {
  let buf = Buffer()
  for i, seg in path {
    if i > 0 {
      buf.write_byte(b'\x00')
    }
    buf.write_bytes(@utf8.encode(seg))
  }
  buf.to_bytes()
}
