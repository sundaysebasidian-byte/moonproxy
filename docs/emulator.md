# proxytest：按 Envoy 行为建模的模拟宿主

`proxytest.HostEmulator` 在进程内实现 proxy-wasm 宿主的全部 host call，插件不进 Envoy 也能在 `moon test` 里跑完整个请求生命周期。它的目标是**在已建模的规则上和 Envoy 一样拒绝错误用法**，让这类错误在单测里暴露，而不是上线后才发现。它不是 Envoy 的完整替身：下表之外的行为没有建模，最终仍以 CI 里的真实 Envoy 端到端测试为准。

下面每条规则都对照 Envoy 源码（`source/extensions/common/wasm/context.cc`、`source/common/buffer/buffer_impl.cc`）和 proxy-wasm-cpp-host 写成，并有对应单测（`proxytest/emulator_test.mbt`）。

## Header 和 trailer

| 规则 | Envoy 中的依据 | 模拟器行为 |
|---|---|---|
| 名字统一小写 | `Http::LowerCaseString` | 写入和查找都转小写 |
| `get_header` 只返回第一个值 | `getHeaderMapValue` 取 `get(key)[0]` | 同 |
| 不存在返回 `NotFound` | 同上 | 同 |
| headers 回调返回 `Continue` 后不能再改 | `decodeHeaders` 返回 Continue 后 `request_headers_ = nullptr` | 该方向的 map 标记为关闭：写和 `get_header` 返回 `BadArgument`；`get_header_map` 返回 `Ok` 和空列表（`getHeaderMapPairs` 对空指针就是这样） |
| headers 回调返回 `Pause` 会停住整个方向 | proxy-wasm-cpp-host `convertVmCallResultToFilterHeadersStatus` 把 `StopIteration` 转成 `StopAllIterationAndWatermark`；Envoy `handleDataIfStopAll` 在本 filter 前缓冲 | 之后到达的 body 分片和 trailers 不交给插件，`call_on_request_body` 直接返回 `Pause`；插件 `resume_http_request` 之后，缓冲的 body 作为一个分片、再加 trailers 依次交给插件 |
| 暂停期间 header 仍可改 | 暂停时指针保留 | 暂停期间保持可写；放行时关闭 |
| 日志阶段只读 | `onLog` 时 map 为 const | 写返回 `BadArgument`，读正常 |
| `replace` 删除同名重复值，只保留一个 | `setCopy` | 同 |

## Body 缓冲区

| 规则 | 依据 | 模拟器行为 |
|---|---|---|
| `set_buffer(start=0, size)` 先丢弃前 `size` 字节再前插 | `Buffer::copyFrom`：`start == 0` 时 `drain(length)` + `prepend` | 同；`size` 超过长度时清空 |
| `start >= 长度` 时追加 | 同上 | 同 |
| 其他 `start` 返回 `BadArgument` | 同上 | 同 |
| 回调返回 `Pause` 时后续分片累积到同一缓冲区 | `StopIterationAndBuffer` | 下一次回调看到的是累积后的全部数据 |
| 返回 `Continue` 才把数据交给上游/客户端 | `decodeData` 返回 Continue 后 `request_body_buffer_ = nullptr` | `forwarded_request_body` 只包含已放行的数据 |
| 带 trailers 的请求，最后一个 data 帧不带 end_of_stream | HTTP/2 帧语义 | trailers 回调返回 `Continue` 时，暂停的 headers 和缓冲的 body 一起放行 |

## 直接回复（`send_http_response`）

- Envoy 用 `addAfterVmCallAction` 把回复推迟到插件回调返回之后再发，回复会经过 filter 链，所以插件自己的 `on_response_headers` / `on_response_body` 也会看到它，在里面做的修改就是客户端最终收到的内容。模拟器在请求阶段回调和 callout 回调返回后照此回放，`local_response` 记录的是回放之后的结果。
- 在响应阶段回调里发的直接回复不回放（Envoy 此时的行为取决于响应头是否已发出，没有建模）。SDK 的 `FailClosed` 在响应阶段不发直接回复，而是 `reset_http_stream` 重置流。

## 流控制

- `continue_stream`：`Request` / `Response` 恢复对应方向；`Downstream` 放行 TCP 下游数据；`Upstream` 返回 `Unimplemented`（Envoy `continueStream` 只实现了前三种）。
- `close_stream(Request/Response)` 重置整个 HTTP 流（Envoy 调用 `resetStream`），`was_reset(id)` 可查；在 TCP 连接上调用返回 `BadArgument`。`Downstream` / `Upstream` 关闭连接。
- `set_tick_period` 在任何上下文里调用都作用于 root（Envoy 如此）。

## 上下文生命周期

- 子上下文在 `proxy_on_context_create` 时只登记父子关系，HTTP 或 TCP 对象在第一个对应回调到来时才创建。这样同一个 root 同时实现 HTTP 和 TCP 时，每条连接拿到的都是正确的那一种（Envoy 在创建时不告诉插件类型）。
- 流结束顺序与 Envoy 一致：HTTP 流是 `on_log`、`on_done`、`on_delete`（HCM 先写访问日志再销毁 filter，`Context::onDestroy` 里才调 `onDone`），`on_done` 时请求和响应头已不可读；TCP 连接是 `on_done`、`on_log`、`on_delete`（`onCloseTCP`）。
- 没有任何回调见过的流（比如被前一个 filter 直接回复）也会收到 `on_log`，SDK 这时才创建流对象（`Context::log` 同样先补 `onCreate`）。
- 插件配置只在 `on_configure` 期间可读，其他时候 `PluginConfiguration` 缓冲返回 `NotFound`（`Context::getBuffer` 只在 `temp_plugin_` 存在时返回）；SDK 的 `get_plugin_configuration` 在 `on_plugin_start` 之外直接报错。

## HTTP callout

- `:method`、`:path`、`:authority` 缺任何一个都返回 `BadArgument`（`Context::httpCall`）。
- 负的超时返回 `BadArgument`。
- `HostEmulator::new(clusters=[...])` 声明存在的 cluster；不在列表里的名字返回 `BadArgument`，和 Envoy 查不到 cluster 时一样。列表为空表示不检查。
- 回调抛错，或响应到了却读不出来，都按 root 的 `error_policy` 处理正在等它的流：`FailOpen` 恢复发起 callout 时所在的方向（请求或响应；TCP 恢复下游），`FailClosed` 在请求阶段回 500、在响应阶段重置流（TCP 断开两端），不会让请求挂到超时。
- 回调触发时，宿主把“当前上下文”切回发起 callout 的那个流（`setEffectiveContext`），所以回调里 `resume_http_request` 作用于正确的请求；流已结束的回调会被丢弃。
- `call_on_http_call_response(token, [], b"")` 模拟超时或连接失败（`num_headers == 0`）。

## Shared data、队列、metrics

- Shared data 的 CAS 规则照 proxy-wasm-cpp-host：`cas != 0` 时必须等于当前版本，否则 `CasMismatch`；每次写入版本号取全局递增计数；新 key 忽略 `cas`。`fail_next_cas(n)` 让接下来 n 次带版本号的写入失败，模拟另一个 worker 抢先写入，用来测试重试和放弃路径。注意新 key 的第一次写入无法做条件写，这是 proxy-wasm 本身的限制。
- 队列：`enqueue` 后调用 `deliver_queue_ready()` 才触发 `on_queue_ready`，便于测试控制时序。
- Counter 只接受正增量（0 和负数返回 `BadArgument`，与 Envoy 一致；SDK 的 `increment(0)` 不调用宿主），同名 metric 返回同一个 id。

## 不模拟的部分

gRPC callout、foreign function、`proxy_get_status`、跨 VM 隔离（所有上下文共享一个模拟 VM）。这些 SDK 目前也没有暴露。另外没有模拟 Envoy 的缓冲上限（超限回 413 或重置）、vm_config 的 `allow_on_headers_stop_iteration` 开关，以及日志阶段读 trailers 的差异。
