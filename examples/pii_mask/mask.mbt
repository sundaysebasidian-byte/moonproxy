///|
/// Length-preserving PII masking for response bodies.
///
/// - e-mail addresses keep the first character of the local part:
///   `alice@example.com` -> `a****@example.com`;
/// - 11-digit mainland China mobile numbers keep 3 + 4 digits:
///   `13812345678` -> `138****5678`, also with the country code written
///   without a space (`+8613812345678` -> `+86138****5678`);
/// - bank card numbers (13 to 19 digits passing the Luhn check) and
///   resident ID numbers (18 characters passing the ISO 7064 MOD 11-2 check)
///   keep only the last 4 characters. The checksums keep timestamps,
///   snowflake ids and order numbers of the same length untouched.
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
fn digit(c : Char) -> Int {
  c.to_int() - '0'.to_int()
}

///|
fn luhn_ok(cs : Array[Char], start : Int, end : Int) -> Bool {
  let mut sum = 0
  let mut double = false
  for k = end - 1; k >= start; k = k - 1 {
    let mut d = digit(cs[k])
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
let id_weights : Array[Int] = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]

///|
let id_check_chars : Array[Char] = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2']

///|
fn resident_id_ok(cs : Array[Char], start : Int) -> Bool {
  let mut sum = 0
  for k in 0..<17 {
    sum += digit(cs[start + k]) * id_weights[k]
  }
  let expected = id_check_chars[sum % 11]
  let got = cs[start + 17]
  got == expected || (got == 'x' && expected == 'X')
}

///|
fn mask_numbers(cs : Array[Char]) -> Unit {
  let n = cs.length()
  let mut i = 0
  while i < n {
    if !cs[i].is_ascii_digit() || (i > 0 && (cs[i - 1].is_ascii_alphabetic() || cs[i - 1].is_ascii_digit())) {
      i += 1
      continue
    }
    let mut j = i
    while j < n && cs[j].is_ascii_digit() {
      j += 1
    }
    let mut len = j - i
    // Resident ID: 17 digits + check character X.
    if len == 17 && j < n && (cs[j] == 'X' || cs[j] == 'x') {
      j += 1
      len = 18
    }
    // A run glued to letters (e.g. a hex id) is not a number we know.
    if j < n && cs[j].is_ascii_alphabetic() {
      i = j
      continue
    }
    if len == 11 && cs[i] == '1' {
      for k in (i + 3)..<(i + 7) {
        cs[k] = '*'
      }
    } else if len == 13 && cs[i] == '8' && cs[i + 1] == '6' && cs[i + 2] == '1' {
      for k in (i + 5)..<(i + 9) {
        cs[k] = '*'
      }
    } else if (len == 18 && resident_id_ok(cs, i)) ||
      (len >= 13 && len <= 19 && cs[j - 1].is_ascii_digit() && luhn_ok(cs, i, j)) {
      for k in i..<(j - 4) {
        cs[k] = '*'
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
