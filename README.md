# moonproxy

[![CI](https://github.com/sundaysebasidian-byte/moonproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/sundaysebasidian-byte/moonproxy/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

用 MoonBit 写 **Envoy 的 Wasm 插件**（proxy-wasm 标准，理论上也适用于 Istio、Higress 等基于 Envoy 的网关）。moonproxy 是 MoonBit 的 [proxy-wasm](https://github.com/proxy-wasm/spec) SDK，实现 ABI v0.2.1，编译出的 `.wasm` 可以直接被 Envoy 加载；同时自带一个**按 Envoy 源码行为建模的模拟宿主**，插件的单元测试不需要启动 Envoy。

在此之前，proxy-wasm 的官方 SDK 只有 C++、Rust、Go（TinyGo）和 AssemblyScript；MoonBit 没有可用实现。

## 能做什么

- **HTTP 过滤器**：读写请求/响应的 header、body、trailer，直接回复（`send_http_response`），暂停与恢复请求。
- **TCP 过滤器**：读写上下游数据，关闭连接。
- **HTTP callout**：插件里调用外部服务（鉴权、风控）。回调拿到已读好的 `HttpCallResponse?`（状态码、header、body、trailer；`None` 表示超时或连不上），并自动回到发起请求的那个流。
- **跨 worker 共享状态**：shared data（带 CAS）、共享队列，Envoy 多线程下也能做全局限流、计数。
- **Metrics**：counter / gauge / histogram，直接出现在 Envoy 的 `/stats` 里。
- **属性、定时器、插件配置、日志**。
- **错误处理**：回调（包括 callout 回调）可以 `raise`，SDK 统一记录日志，再按 root 的 `error_policy` 处理当前的流：默认 `FailOpen` 放行；返回 `FailClosed` 则回 500 或断开连接，鉴权类插件出错不会把请求放过去。

## 示例插件

`examples/` 下的插件都有单测，并在 CI 里编译成 wasm、放进真实 Envoy 跑端到端测试。

| 插件 | 做什么 | 用到的能力 |
|---|---|---|
| [http_headers](examples/http_headers/plugin.mbt) | 给响应加 header，记录请求行 | 最小示例、配置解析 |
| [api_key_auth](examples/api_key_auth/plugin.mbt) | API Key 鉴权，401/403，向上游传身份 | 直接回复、`FailClosed`、metrics |
| [rate_limit](examples/rate_limit/plugin.mbt) | 按源 IP（或上游鉴权写入的 header）令牌桶限流，所有 worker 共享；客户端 key 哈希到固定数量的桶，内存有上限 | shared data + CAS 重试、属性 |
| [ext_authz](examples/ext_authz/plugin.mbt) | 外部鉴权服务，通过则回填身份 header | HTTP callout、暂停/恢复 |
| [pii_mask](examples/pii_mask/plugin.mbt) | 响应里的邮箱、手机号（含 `+86`）、银行卡号（Luhn）、身份证号（校验位）脱敏；按字节处理，长度不变；去掉 `accept-encoding` 防止压缩绕过 | 缓冲整个 body、改写 body |
| [ai_guard](examples/ai_guard/plugin.mbt) | OpenAI 兼容接口（chat/completions、completions、responses）的模型白名单、敏感词拦截、token 上限（非数字的上限直接拒绝）；路径先规范化，`%XX`、`;参数`、重复或结尾的 `/` 绕不过去。body 在判定前不会到达上游，但请求头会先到（见插件文档） | 缓冲、解析、改写 JSON body |
| [tcp_quota](examples/tcp_quota/plugin.mbt) | 每连接流量统计，超额断开（断开后不再转发） | TCP 过滤器、属性 |
| [minimal](examples/minimal/plugin.mbt) | 下面“快速开始”里的代码原样放在这里 | 保证 README 示例能编译、能过测试、能在 Envoy 里跑 |

## 快速开始

### 1. 写插件

```moonbit
priv struct Root {}

impl @moonproxy.RootContext for Root with new_http_context(_, _) {
  Some(Stream::{  })
}

priv struct Stream {}

impl @moonproxy.HttpContext for Stream with on_request_headers(_, _, _) {
  if @moonproxy.get_request_header("x-api-key") is None {
    @moonproxy.send_http_response(401, [], b"missing key")
    return Pause
  }
  @moonproxy.add_request_header("x-checked-by", "moonbit")
  Continue
}

fn init {
  @moonproxy.set_root_context(fn(_) { Root::{  } })
}
```

`moon.pkg`：

```
import {
  "sundaysebasidian-byte/moonproxy" @moonproxy,
}

import {
  "sundaysebasidian-byte/moonproxy/proxytest" @proxytest,
} for "test"
```

然后生成 ABI 导出（`exports.mbt`，以及 `moon.pkg` 里 `options(link: ...)` 的 wasm 导出列表；`moon.pkg` 里其他内容会保留）。脚本只依赖 Python 3 标准库，从本仓库复制一份即可：

```sh
curl -fsSLO https://raw.githubusercontent.com/sundaysebasidian-byte/moonproxy/main/scripts/gen_exports.py
python3 gen_exports.py path/to/your_plugin
```

需要按 Envoy 的错误处理来时，在 root 上实现 `error_policy`：

```moonbit
impl @moonproxy.RootContext for Root with error_policy(_) {
  FailClosed
}
```

调用外部服务的写法（完整示例见 [ext_authz](examples/ext_authz/plugin.mbt)）：

```moonbit
let _ = @moonproxy.dispatch_http_call(
  "authz",                                   // Envoy cluster 名
  [(":method", "GET"), (":path", "/check"), (":authority", "authz")],
  timeout_ms=500,
  fn(answer) raise {
    match answer {
      Some(r) if r.status_code == 200 => @moonproxy.resume_http_request()
      _ => @moonproxy.send_http_response(403, [], b"denied")
    }
  },
)
```

`on_request_headers` 返回 `Pause` 时，Envoy 会把整个请求方向停住（proxy-wasm-cpp-host 把它转成 `StopAllIterationAndWatermark`）：恢复之前 body 和 trailer 回调都不会被调用，恢复后缓冲的 body 一次交给插件。所以 headers 阶段的 `Pause` 之后必须有人恢复或回复（比如上面的 callout 回调）；只想检查 body 的插件应在 headers 阶段返回 `Continue`、在 body 阶段返回 `Pause`（见 ai_guard）。模拟宿主按同样的规则执行，写错了单测会直接挂住而不是通过。

### 2. 不启动 Envoy 写单测

```moonbit
test "rejects requests without a key" {
  let emu = @proxytest.HostEmulator::new()
  assert_true(emu.start())
  let id = emu.init_http()
  inspect(emu.call_on_request_headers(id, [(":path", "/")]), content="Pause")
  guard emu.local_response(id) is Some(r) else { fail("expected 401") }
  inspect(r.status_code, content="401")
}
```

模拟宿主在已建模的规则上像 Envoy 一样拒绝错误用法，例如 headers 阶段已经放行后再改 header 会得到 `BadArgument`；还可以声明存在的 cluster、注入 CAS 冲突。规则清单见 [docs/emulator.md](docs/emulator.md)。

### 3. 编译并放进 Envoy

```sh
moon build --target wasm --release
# 产物：_build/wasm/release/build/<包路径>/<包名>.wasm（旧版 moon 在 target/ 下）
```

插件里不要用 `println`：它依赖 WASI，Envoy 不提供，模块会加载失败。输出用 `@moonproxy.log_info` 等函数。

```yaml
http_filters:
  - name: envoy.filters.http.wasm
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
      config:
        configuration:
          "@type": type.googleapis.com/google.protobuf.StringValue
          value: '{"header": "x-powered-by", "value": "moonbit"}'
        vm_config:
          runtime: envoy.wasm.runtime.v8
          code: { local: { filename: /plugins/your_plugin.wasm } }
  - name: envoy.filters.http.router
```

完整可运行的配置见 [e2e/envoy_config.py](e2e/envoy_config.py)。Istio 的 `WasmPlugin`、Higress 的自定义插件加载的也是 proxy-wasm 模块，但本项目只在原生 Envoy 上做过端到端验证。

## 验证

CI（[ci.yml](.github/workflows/ci.yml)）为每次提交配置了以下检查，每次运行的结果在 Actions 页面：

1. 在 wasm、wasm-gc、js、native 四个后端做类型检查（`--deny-warn`），在 wasm-gc、js、native 上跑全部单测；
2. 把 8 个示例编译成 wasm，用 [check_wasm.cjs](scripts/check_wasm.cjs) 逐个检查导出函数签名、内存导出，以及只导入 proxy-wasm host call；再用 [ffi_test.cjs](scripts/ffi_test.cjs)（一个用 JS 写的最小 proxy-wasm 宿主）直接通过 ABI 驱动编译好的模块：检查 header map 序列化、宿主分配的内存交给插件后的读写、i64 参数，并跑 2 万个请求确认线性内存不增长（引用计数没有泄漏）；
3. 在 Envoy v1.34（4 个 worker 线程）里加载全部插件跑[端到端测试](e2e/run.py)，包括限流（先 1 个请求、再 39 个并发请求共享一个桶）、分块响应里跨块的手机号脱敏、callout 鉴权（被拒的 POST body 不会到达上游、鉴权服务挂掉时 fail-open 不透传伪造身份）、ai_guard 的路径绕过、Envoy `/stats` 里的插件指标；固定版本和最新版 MoonBit 各跑一遍；
4. 用 wrk 对比同一个插件的 MoonBit 版和官方 Rust SDK 版（[bench/](bench/)）：Envoy 用 `direct_response` 直接回复，排除后端干扰，三种情况轮换顺序跑多轮，报告中位数和波动范围。

开发中审查和测试实际发现过哪些问题、现在由哪条测试守住，见 [docs/verification.md](docs/verification.md)。

## 限制与未完成事项

- 只支持 `wasm` 后端（proxy-wasm 要求线性内存）；其他后端可以编译和跑单测，但不能产出插件。
- 暂不支持 gRPC callout、foreign function；`Action` 只有 `Continue` / `Pause`，与 Rust SDK 一致。
- 模拟宿主没有模拟 Envoy 的缓冲上限（超限时 Envoy 回 413 或重置流），也没有模拟 vm_config 里的 `allow_on_headers_stop_iteration` 开关。
- shared data 没有过期机制，新 key 的第一次写入无法做条件写，这两点是 proxy-wasm 本身的限制（见 rate_limit 示例的说明）。
- 线性内存 FFI 依赖 MoonBit 运行时的 `$moonbit.gc.malloc` / `decref`（与 wit-bindgen 的 MoonBit 绑定相同），编译器若改动这部分需要跟进；CI 用固定版本和最新版两个工具链各构建并在 Envoy 中跑一遍来发现这类变化。
- 端到端测试只覆盖原生 Envoy，没有在 Istio、Higress 上验证。

## 许可证

[Apache-2.0](LICENSE)
