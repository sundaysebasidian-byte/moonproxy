///|
test "paths are normalised before matching" {
  inspect(normalize_path("/A//b%2Fc/?q"), content="/a/b/c")
  inspect(
    normalize_path("/v1/Chat//complet%69ons/"),
    content="/v1/chat/completions",
  )
  inspect(normalize_path(""), content="/")
  // Dot segments and backslashes, plain or percent-encoded.
  inspect(
    normalize_path("/v1/chat/completions/."),
    content="/v1/chat/completions",
  )
  inspect(
    normalize_path("/v1/chat/completions/x/.."),
    content="/v1/chat/completions",
  )
  inspect(
    normalize_path("/v1/x/%2e%2e/chat\\completions"),
    content="/v1/chat/completions",
  )
  inspect(
    normalize_path("/v1/chat%5ccompletions/..;x/completions"),
    content="/v1/chat/completions",
  )
  inspect(normalize_path("/../../a"), content="/a")
  inspect(
    normalize_path("/v1/chat;x=1/completions;jsessionid=2"),
    content="/v1/chat/completions",
  )
}
