# Changelog

## 0.1.0

First release.

- proxy-wasm ABI v0.2.1 SDK: HTTP and TCP filters, header/body/trailer access,
  local responses, HTTP callouts with an eagerly read `HttpCallResponse?`,
  shared data with CAS, shared queues, metrics, properties, timers, logging.
- Error policy per root context (`FailOpen` / `FailClosed`), applied to every
  callback including callout callbacks; in the response phase `FailClosed`
  resets the stream (`reset_http_stream`) instead of sending a 500.
- HTTP or TCP context objects are created on the first callback, so one root
  can serve both kinds of filter.
- Stream end follows Envoy: `on_log`, `on_done`, `on_delete` for HTTP
  (`on_done`, `on_log`, `on_delete` for TCP); a stream no callback saw is
  still logged. `get_plugin_configuration` raises outside `on_plugin_start`,
  where Envoy no longer serves the configuration.
- `proxytest`: in-process host modelled on Envoy (header map lifetimes, buffer
  `copyFrom` semantics, `Pause` on headers stopping the whole direction as in
  proxy-wasm-cpp-host, deferred local responses, stream reset, cluster
  lookup, CAS conflict injection).
- Examples: http_headers, api_key_auth, rate_limit, ext_authz, pii_mask,
  ai_guard, tcp_quota, minimal.
- Tooling: export generator, wasm ABI checker, a JS proxy-wasm host that
  drives the compiled modules through the raw ABI (memory and reference
  counting checks), Envoy end-to-end test, benchmark against the proxy-wasm
  Rust SDK.
