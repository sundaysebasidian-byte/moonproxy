# 验证闭环：发现了什么、怎么防止再犯

开发中每一轮都按“按评分标准独立审查 → 写出能复现问题的测试 → 修复 → 测试进入回归”的顺序走。下表是审查和测试实际发现的问题，以及现在守住它的测试。真实 Envoy 里的行为由 [e2e/run.py](../e2e/run.py) 在 CI 中复核。

| 发现的问题 | 后果 | 守住它的测试 |
|---|---|---|
| ext_authz：担心 headers 暂停后 body 回调返回 `Continue` 会提前放行（Envoy 默认不会调用它，但开启 `allow_on_headers_stop_iteration` 的宿主会） | 带 body 的 POST 在鉴权结果回来前就被转发，副作用已经发生 | `ext_authz` 单测 “the request body waits for the verdict”；e2e “denied POST body never reaches the upstream” |
| ext_authz：fail-open 分支没有先删客户端自带的身份头 | 鉴权服务挂掉时可以伪造 `x-user-id` | 单测 “fail open never forwards a forged identity”；e2e “fail open strips forged identity” |
| ai_guard / pii_mask：只在 `end_of_stream` 的 data 帧上检查 | 带 trailers 的 HTTP/2 请求或响应，缓冲的 body 未经检查就放行 | 单测 “a request that ends with trailers is still checked”、“a body that ends with trailers is masked before it leaves” |
| pii_mask：`contains("json")` 命中 `application/grpc+json` | gRPC 二进制帧被当成文本改写 | 单测 “grpc responses are not treated as text” |
| pii_mask：13–19 位数字一律当银行卡 | 毫秒时间戳、雪花 id、订单号被误伤 | 单测 “checksums keep look-alike numbers”（Luhn + 身份证 MOD 11-2 校验） |
| rate_limit：补充量按毫秒截断，且每次请求都把时间戳推到当前 | 同一个 key 的请求间隔小于 1 ms 时令牌桶永远不回血 | 白盒测试 “requests closer than a millisecond still refill the bucket”（0.5 ms 间隔、1 秒内放行 10 个） |
| rate_limit：极旧的桶计算补充量时 `elapsed * rate` 溢出 | 限流结果错乱 | 白盒测试 “a very old bucket comes back full without overflow” |
| rate_limit：CAS 冲突重试和放弃路径没有测试 | 并发下的行为只能靠猜 | 单测 “a lost CAS race is retried”、“endless CAS conflicts fail open”（模拟宿主 `fail_next_cas` 注入冲突） |
| SDK：callout 回调抛错只记日志 | `FailClosed` 插件的请求一直挂到超时 | `proxytest` 单测 “a raising callout callback never leaves the stream hanging” |
| 模拟宿主：HTTP 流按 done → log → delete 结束 | Envoy 的 HTTP 流实际是 log → done → delete，在 `on_done` 里读头的插件单测能过、上线拿不到 | 单测 “an HTTP stream ends with log, then done, as in Envoy”（`on_done` 读头得到 `BadArgument`） |
| SDK：没有回调见过的流不调 `on_log` | 被前一个 filter 直接回复的请求不进插件的访问日志 | 单测 “a request no callback saw is still logged” |
| 模拟宿主：插件配置随时可读 | Envoy 只在 `on_configure` 期间提供，插件在请求里读配置单测能过、上线得到空配置 | 单测 “the plugin configuration is only served during on_plugin_start” |
| ai_guard：`max_tokens` 写成字符串或 `null` 绕过上限；`/responses` 加错字段 | 上游可能把 `"99999"` 当数字用 | 单测 “token limits must be numbers; null or none gets the cap” |
| tcp_quota：触发关闭后的数据仍 `Continue` | 关闭是异步的，期间还会转发 | 关闭后一律 `Pause` |
| pii_mask：出错时默认放行；`+86` 手机号漏掩码 | 未掩码的响应发出 | `FailClosed`；单测覆盖 `+8613812345678` |
| rate_limit：`burst` 过大导致毫令牌运算溢出 | 配置错误变成限流失效 | 配置上限 1e9 |
| api_key_auth：重新配置失败时已清空旧 key | 坏配置推下去后所有请求被拒 | 先解析到局部变量，成功后再替换 |
| e2e：TCP 超时被当成“已关闭” | 配额失效时测试仍通过 | 超时算失败 |
| SDK：子上下文在创建时就先尝试 HTTP | 同时实现 HTTP 和 TCP 的 root，TCP 连接拿到错误的对象 | 单测 “a root with both HTTP and TCP filters gets the right kind per stream” |
| 模拟宿主：直接回复立刻生效，不经过插件自己的响应回调 | 与 Envoy（`addAfterVmCallAction` 推迟发送）不一致，单测会漏掉插件对自身回复的处理 | 单测 “a local response runs through the plugin's own response callbacks” |
| 模拟宿主：任何 cluster 名都能 callout | Envoy 里拼错 cluster 会得到 `BadArgument`，单测却通过 | 单测 “callouts to an unknown cluster fail like in Envoy” |
| README 示例没有被编译 | 文档代码与 API 脱节 | `examples/minimal` 原样收录 README 代码，CI 编译、测试并放进 Envoy 跑 |
| 模拟宿主：headers 返回 `Pause` 后照样把 body 交给插件（`StopIteration` 语义） | 与 Envoy 不符：cpp-host 把它转成 `StopAllIterationAndWatermark`，body 回调在恢复前不会被调用。ai_guard 依赖错误的语义，在真实 Envoy 里请求会一直挂住，单测却通过 | 单测 “Pause on headers holds body and trailers until the plugin resumes”；修正后 ai_guard 原有 5 条单测全部失败，暴露了这个问题，ai_guard 改为 headers 阶段放行、body 阶段暂停 |
| ai_guard：只认路径后缀 `/chat/completions` | `complet%69ons`、结尾 `/`、`/v1/responses` 等都能绕过白名单和敏感词 | 单测 “path tricks and other LLM endpoints are checked too”；e2e “/v1/Chat//complet%69ons/ is checked” |
| rate_limit：key 取自客户端可控的 header | 每次换一个值就拿到满桶；shared data 不过期，还能撑爆内存 | 单测 “without key_header clients are told apart by source IP”；白盒 “any number of client keys maps onto the configured buckets” |
| pii_mask：客户端带 `accept-encoding: gzip` | 上游压缩响应，插件跳过，数据原样泄露 | 单测 “accept-encoding is stripped”；e2e “upstream never asked for compression” |
| pii_mask：先按 UTF-8 解码再编码 | 非法 UTF-8 的正文长度改变、内容损坏 | 单测 “invalid UTF-8 around PII keeps every byte and the length” |
| ext_authz：只转发第一个 `authorization` | 重复的头让鉴权服务和上游看到不同身份 | 单测 “a duplicated forwarded header is rejected before any callout” |
| SDK：callout 失败一律恢复请求方向 | 响应阶段发起的 callout 出错后，响应方向一直挂住 | 单测 “a callout from the response phase fails in the response direction” |
| SDK：响应阶段 `FailClosed` 仍发 500 | 响应头可能已发出，直接回复失败被吞掉，流挂住 | 单测 “FailClosed in a response callback resets the stream” |
| SDK：`increment(0)` 调用宿主 | Envoy 对 0 返回 `BadArgument`，插件报错 | 模拟宿主改为与 Envoy 一致地拒绝 0；SDK 对 0 直接返回 |
| SDK：root 拒绝创建流后，每个回调都再问一次 | 多余调用，且插件可能有副作用 | 单测 “a root that declines a stream is asked only once” |
| FFI：`malloc` 没按参考实现多分配 4 字节，out 参数槽未清零 | 只能在 wasm 里出现的内存问题，Envoy e2e 未必能稳定复现 | `scripts/ffi_test.cjs` 用 JS 宿主直接驱动编译后的模块，含 2 万次请求的内存不增长检查 |
| pii_mask：只认连续数字 | `138 0013 8000`、`138-0013-8000`、`+86 138…`、分组银行卡号和 15 位旧身份证原样通过 | 单测 “grouped and prefixed numbers”、“old 15-digit ids and the mobile prefix” |
| pii_mask：客户端带 `range` | 上游只回一段，插件看到的数字被截断在块边界上，脱敏规则匹配不上 | 单测 “accept-encoding and range are stripped so the upstream sends the whole body in plain text”；e2e 检查上游收不到 `range` |
| pii_mask：没有 `content-type` 的响应被当成二进制跳过 | 上游漏写类型就能绕过脱敏 | 单测 “a body without content-type is still masked”；e2e `/pii-untyped` |
| pii_mask：`text/event-stream` 等到流结束才放行 | LLM 流式回复被整段缓冲，客户端拿不到流 | 单测 “server-sent events stream event by event, masked”；e2e 检查第一条事件在上游暂停前就到达客户端 |
| ai_guard：`.`、`..`、`\`、`;参数` 没有规范化 | `/v1/chat/completions/x/..` 等路径绕过检查 | 白盒测试补充点段和反斜杠用例；e2e 两条点段路径必须被拒 |
| ai_guard：不限制 `n` / `best_of` | 一次请求拿到多份补全，`max_tokens` 上限被放大 | 单测 “n and best_of are limited to max_choices” |
| rate_limit：桶号是不带种子的 FNV-1a | 客户端能离线挑出落在别人桶里的 key | 白盒 “the hash seed moves clients between buckets”；种子写进 shared data，所有 worker 共用 |
| rate_limit：IPv6 按完整地址区分 | 一个 /64 内换地址就拿到新桶 | 白盒 “IPv6 clients are grouped by /64” |
| tcp_quota：关闭后暂停的数据恢复时被重复计数；`max_bytes` 写成小数或负数被接受 | 统计偏大；配置错误不报 | 单测 “invalid configuration stops the plugin” 及关闭后计数的检查 |
| 模拟宿主：直接回复之后请求 body 仍交给插件和上游 | 与 Envoy 不一致，被拒请求的 body 在单测里像是被转发了 | 单测 “request data after a local response reaches neither the plugin nor the upstream” |
