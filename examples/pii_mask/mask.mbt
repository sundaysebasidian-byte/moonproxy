///|
/// Length-preserving PII masking for response bodies.
///
/// - e-mail addresses keep the first character of the local part:
///   `alice@example.com` -> `a****@example.com`;
/// - mainland China mobile numbers (11 digits, `1[3-9]...`) keep 3 + 4
///   digits: `13812345678` -> `138****5678`; also written `138 1234 5678`,
///   `138-1234-5678` or with the country code (`+8613812345678`,
///   `+86 138 1234 5678`);
/// - bank card numbers (13 to 19 digits passing the Luhn check, plain or in
///   groups of 3 to 6 digits such as `6222 0212 3456 7890 128`), resident
///   ID numbers (18 characters passing the ISO 7064 MOD 11-2 check) and
///   15-digit pre-2004 IDs (area code and a plausible birth date) keep only
///   the last 4 characters. The checksums keep timestamps, snowflake ids and
///   order numbers of the same length untouched; a 15-digit ID has no
///   checksum, so other 15-digit numbers with a valid-looking date in that
///   position are masked too.
///
/// Every replaced character is ASCII and becomes one `*`, so the byte
/// length never changes and `content-length` stays valid.

///|
fn is_local_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() ||
  c.is_ascii_digit() ||
  c == '.' ||
  c == '_' ||
  c == '%' ||
  c == '+' ||
  c == '-'
}

///|
fn is_domain_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '.' || c == '-'
}

///|
fn mask_emails(cs : Array[Char]) -> Unit {
  let n = cs.length()
  for i in 0..<n {
    if cs[i] != '@' {
      continue
    }
    let mut s = i
    while s > 0 && is_local_char(cs[s - 1]) {
      s -= 1
    }
    let mut e = i + 1
    while e < n && is_domain_char(cs[e]) {
      e += 1
    }
    while e > i + 1 && (cs[e - 1] == '.' || cs[e - 1] == '-') {
      e -= 1
    }
    let domain_ok = e > i + 1 &&
      cs[i + 1] != '.' &&
      cs[i + 1:e].iter().any(fn(c) { c == '.' })
    if s < i && domain_ok {
      for k in (s + 1)..<i {
        cs[k] = '*'
      }
    }
  }
}

///|
fn digit(c : Char) -> Int32 {
  c.to_int() - '0'.to_int()
}

///|
let id_weights : Array[Int32] = [
  7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2,
]

///|
let id_check_chars : Array[Char] = [
  '1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2',
]

///|
fn resident_id_ok(cs : Array[Char], start : Int32) -> Bool {
  let mut sum = 0
  for k in 0..<17 {
    sum += digit(cs[start + k]) * id_weights[k]
  }
  let expected = id_check_chars[sum % 11]
  let got = cs[start + 17]
  got == expected || (got == 'x' && expected == 'X')
}

///|
fn mask_range(cs : Array[Char], pos : Array[Int32], from : Int32, to : Int32) -> Unit {
  for k in from..<to {
    cs[pos[k]] = '*'
  }
}

///|
fn is_mobile(cs : Array[Char], pos : Array[Int32], at : Int32) -> Bool {
  cs[pos[at]] == '1' && cs[pos[at + 1]] >= '3' && cs[pos[at + 1]] <= '9'
}

///|
/// Pre-2004 15-digit resident ID: 6-digit area code, YYMMDD, 3 digits.
/// There is no check digit, so the area and the date must look real.
fn old_id_ok(cs : Array[Char], pos : Array[Int32]) -> Bool {
  let d = fn(k : Int32) { digit(cs[pos[k]]) }
  let month = d(8) * 10 + d(9)
  let day = d(10) * 10 + d(11)
  d(0) >= 1 && d(0) <= 8 && month >= 1 && month <= 12 && day >= 1 && day <= 31
}

///|
/// Apply the number rules to one token: `pos` are the indexes of its
/// characters (digits, plus a final `X` for an ID), `groups` the lengths of
/// its separator-delimited groups (one group when it has no separators).
fn mask_token(
  cs : Array[Char],
  pos : Array[Int32],
  groups : Array[Int32],
) -> Bool {
  let len = pos.length()
  let plain = groups.length() == 1
  let has_x = !cs[pos[len - 1]].is_ascii_digit()
  if has_x {
    if len == 18 && plain && resident_id_ok(cs, pos[0]) {
      mask_range(cs, pos, 0, 14)
      return true
    }
    return false
  }
  if len == 11 && is_mobile(cs, pos, 0) && (plain || groups == [3, 4, 4]) {
    mask_range(cs, pos, 3, 7)
    return true
  }
  if len == 13 &&
    cs[pos[0]] == '8' &&
    cs[pos[1]] == '6' &&
    is_mobile(cs, pos, 2) &&
    (plain || groups == [2, 11] || groups == [2, 3, 4, 4]) {
    mask_range(cs, pos, 5, 9)
    return true
  }
  if len == 18 && plain && resident_id_ok(cs, pos[0]) {
    mask_range(cs, pos, 0, 14)
    return true
  }
  if len == 15 && plain && old_id_ok(cs, pos) {
    mask_range(cs, pos, 0, 11)
    return true
  }
  // Card numbers are printed in groups of 4 (Amex: 4-6-5).
  if len >= 13 &&
    len <= 19 &&
    (plain || groups.iter().all(fn(g) { g >= 3 && g <= 6 })) &&
    luhn_ok_at(cs, pos) {
    mask_range(cs, pos, 0, len - 4)
    return true
  }
  false
}

///|
fn luhn_ok_at(cs : Array[Char], pos : Array[Int32]) -> Bool {
  let mut sum = 0
  let mut double = false
  for k = pos.length() - 1; k >= 0; k = k - 1 {
    let mut d = digit(cs[pos[k]])
    if double {
      d = d * 2
      if d > 9 {
        d -= 9
      }
    }
    sum += d
    double = !double
  }
  sum % 10 == 0
}

///|
fn mask_numbers(cs : Array[Char]) -> Unit {
  let n = cs.length()
  let mut i = 0
  while i < n {
    if !cs[i].is_ascii_digit() ||
      (i > 0 && (cs[i - 1].is_ascii_alphabetic() || cs[i - 1].is_ascii_digit())) {
      i += 1
      continue
    }
    // Digits, optionally in groups joined by one space or one hyphen (the
    // same separator throughout), e.g. `138 1234 5678`, `6222-0212-...`.
    let pos : Array[Int32] = []
    let groups : Array[Int32] = []
    let mut sep = '\u{0}'
    let mut j = i
    while true {
      let g = j
      while j < n && cs[j].is_ascii_digit() {
        pos.push(j)
        j += 1
      }
      groups.push(j - g)
      if j + 1 < n &&
        (cs[j] == ' ' || cs[j] == '-') &&
        (sep == '\u{0}' || cs[j] == sep) &&
        cs[j + 1].is_ascii_digit() {
        sep = cs[j]
        j += 1
      } else {
        break
      }
    }
    // Resident ID: 17 digits + check character X.
    if groups.length() == 1 && pos.length() == 17 && j < n && (cs[j] == 'X' || cs[j] == 'x') {
      pos.push(j)
      j += 1
    }
    // A run glued to letters (e.g. a hex id) is not a number we know.
    if j < n && cs[j].is_ascii_alphabetic() {
      i = j
      continue
    }
    if !mask_token(cs, pos, groups) && groups.length() > 1 {
      // Not one grouped number: try each group on its own, e.g. two phone
      // numbers separated by a space.
      let mut at = 0
      for g in groups {
        let p = Array::makei(g, fn(k) { pos[at + k] })
        let _ = mask_token(cs, p, [g])
        at += g
      }
    }
    i = j
  }
}

///|
pub fn mask_pii(text : String) -> String {
  let cs = text.to_array()
  mask_emails(cs)
  mask_numbers(cs)
  String::from_array(cs)
}

///|
/// `mask_pii` on raw bytes, whatever their encoding: each byte is treated
/// as one character, so only ASCII is ever matched or replaced and every
/// other byte (UTF-8 sequences, invalid UTF-8, Latin-1) is left exactly as
/// it was. The output always has the input's length.
pub fn mask_pii_bytes(body : Bytes) -> Bytes {
  let cs = Array::makei(body.length(), fn(i) { body[i].to_char() })
  mask_emails(cs)
  mask_numbers(cs)
  Bytes::makei(cs.length(), fn(i) { cs[i].to_int().to_byte() })
}
