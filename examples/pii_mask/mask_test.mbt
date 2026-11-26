///|
test "emails" {
  inspect(
    @pii_mask.mask_pii("mail alice.w@example.com or bob@sub.example.cn."),
    content="mail a******@example.com or b**@sub.example.cn.",
  )
  // Not addresses: no dot in the domain, no local part, leading dot.
  inspect(
    @pii_mask.mask_pii("user@localhost @example.com a@.com"),
    content="user@localhost @example.com a@.com",
  )
}

///|
test "phones, cards and ids" {
  inspect(
    @pii_mask.mask_pii(
      "{\"phone\":\"13812345678\",\"card\":\"6222021234567890128\"}",
    ),
    content="{\"phone\":\"138****5678\",\"card\":\"***************0128\"}",
  )
  inspect(
    @pii_mask.mask_pii("visa 4111111111111111"),
    content="visa ************1111",
  )
  inspect(
    @pii_mask.mask_pii("id 11010519491231002X"),
    content="id **************002X",
  )
  inspect(
    @pii_mask.mask_pii("tel +8613812345678"),
    content="tel +86138****5678",
  )
  // Other lengths, numbers glued to letters, and non-mobile prefixes stay.
  inspect(
    @pii_mask.mask_pii(
      "order 20240101 v13812345678 23812345678 sha 1234567890123abc",
    ),
    content="order 20240101 v13812345678 23812345678 sha 1234567890123abc",
  )
}

///|
test "checksums keep look-alike numbers" {
  // A millisecond timestamp, a snowflake-style id, a card number with a
  // wrong check digit and an 18-digit number that is not a valid ID.
  let text = "ts 1732550000000 id 1866251515153414144 card 6222020200112233445 n 110105194912310021"
  inspect(@pii_mask.mask_pii(text), content=text)
}

///|
test "masking never changes the UTF-8 length" {
  let samples = [
    "", "联系人：张三 13912345678，邮箱 zhang.san@corp.example", "6222020200112233445",
    "@@@..13812345678@x.y", "ünïcödé a@b.cd 1381234567812",
  ]
  for s in samples {
    let m = @pii_mask.mask_pii(s)
    assert_eq(@utf8.encode(m).length(), @utf8.encode(s).length())
  }
}
