# 网络代理（链路管理 → 代理）

## 用途

app 的所有出站请求都可以走一个 HTTP 代理，适用于受控网络 / 企业出口，
也用于抓包排查接口问题。默认关闭（未填写 = `DIRECT` 直连），对所有用户可见，
不是隐藏的调试开关，可以长期开启。

## 支持的代理类型

| 类型 | 状态 | 原因 |
| --- | --- | --- |
| HTTP | 支持 | `dart:io` 的 `findProxy` 只接受 `PROXY host:port`；HTTPS 目标通过 `CONNECT` 隧道转发 |
| HTTPS | 不支持 | 需要先与代理本身建立 TLS，`dart:io` 的代理配置没有这个能力 |
| SOCKS5 | 不支持 | 需要自定义 Socket 建连与 SOCKS5 握手（`connectionFactory`），当前未实现 |

`dart:io` 的 `_ProxyConfiguration` 会拒绝除 `PROXY host:port` / `DIRECT`
之外的写法（直接抛 `HttpException`），所以不要在设置里假装支持后两者。

## 字段

- **类型**：仅 HTTP 可保存；HTTPS / SOCKS5 在列表里置灰并给出说明。
- **主机 / 端口**：分开填写。端口必须为 1–65535，主机不能为空。
- **用户名 / 密码（可选）**：代理返回 `407 Proxy Authentication Required` 时
  用 Basic 认证自动重试；密码输入框默认遮挡，可切换显示。
- **忽略列表（可选）**：逗号分隔，命中则直连。支持
  `localhost`、`127.0.0.1` 这类精确值，以及 `*.internal`、`.corp` 这类后缀写法。

## 生效范围

- `lib/services/proxy_config.dart` 通过 `HttpOverrides.global` 给所有
  `dart:io` `HttpClient` 设置 `findProxy`。`package:http` 的 API 请求、
  multipart 上传、`Image.network` 的封面 / 正文图片全部走同一个代理。
- 未配置时完全不干预（`HttpOverrides.global = null`），行为与不设代理一致。
- 保存后调用 `Repository.refreshTransport()` 重建 `http.Client`：
  新请求立刻使用新配置，旧 client 延迟 30 秒关闭，不会掐断进行中的请求。

## 可用性检测

- 保存前自动探测一次，也可以随时点「测试连接」。
- 探测先做 4 秒 TCP 建连，再向代理发一次 `CONNECT example.com:443`：
  - 连不上端口 → 「连不上代理 host:port，请检查主机与端口」
  - 返回 407 → 「代理要求认证，用户名或密码不正确」
  - 返回其它合法 HTTP 状态（含代理拒绝隧道）→ 视为代理可用
  - 响应不是 HTTP / 读取超时 → 「能连上，但对方不是可用的 HTTP 代理」
- 探测失败不阻止保存（可能只是当前网络不通），但会给出对应提示。
- 链路探测同样受代理影响：探测失败且判定为代理问题时，该链路状态显示
  「不可达 · 代理不可用」，不会误报成线路故障。代理变更后
  `Repository.refreshTransport()` 会一并重建探测 client（`findProxy` 在创建时绑定）。

## 请求失败如何归因

请求层（`ApiClient`）把失败分成三类，界面文案不同：

| 类别 | 判定 | 界面 |
| --- | --- | --- |
| 代理不可用 | 连不上代理端口、407 认证失败、代理隧道中断、代理拦截导致的 TLS 握手失败 | 「代理不可用」+「去设置代理」入口（仅经代理失败时出现，且**不**切换线路） |
| 线路不可达 | 代理正常但域名 / 连接失败，或网关返回 502 / 503 / 504 | 「线路不可用」+ 重试 |
| 业务错误 | 信封 `code != 200` | 原样透出服务端 `message` |

走代理时，`dart:io` 抛出的 `SocketException` 里地址往往是**代理**而不是目标站，
所以不能据此认定目标站挂了。`ProxyConfig.isProxyFailure()` 按代理 `host:port`、
错误码（111/110/113/101）、`HandshakeException` / `HttpException` 判断归属；
命中忽略列表而直连的请求不会归因代理。

## 持久化与安全

- 配置以 JSON 存在 SharedPreferences（`pref_proxy`），`main()` 在 `runApp`
  之前恢复，保证启动后的第一个 HttpClient 就带代理；重启后保持。
- 旧版本保存的纯文本 `host:port` 会自动迁移。
- **密码是明文保存在 SharedPreferences 的**（未使用 Keychain / Keystore），
  设置页有明确提示。不要在不可信的设备或共享设备上填写代理密码。

## 能看到什么层级（抓包）

| 代理能力 | 可见内容 |
| --- | --- |
| 普通 HTTP 代理（支持 CONNECT） | 目标 `Host:Port`、CONNECT 是否成功、TLS 连接时长与流量 |
| MITM 且证书被 app 信任 | 完整 URL、请求头、响应体（含明文 JSON） |
| MITM 但证书未被信任 | CONNECT 后 TLS 握手失败，只能看到域名与连接级信息 |

**证书限制**：Flutter / `dart:io` 使用自己的根证书集合，不读取系统「用户证书」。
即使把 Reqable / Charles 的 CA 装进 Android 用户证书，app 内请求仍会握手失败。
因此默认实现下最可靠的观察层级是**连接级**（域名、端口、数量、大小）；
要看明文需要把 CA 预置进 app 的信任链（打包时加入 `SecurityContext`），
本仓库未做这一层，不要假设代理能解出具体请求内容。

## 注意

- 代理只转发，不改写请求头；`Host` 由 `dart:io` 按目标 URL 隐式生成
  （CDN 与 API 是两个不同 host），签名头 `X-Auth-Timestamp/Signature` 仍在 app 内生成。
- 清空主机与端口并保存（或点「清除代理」）立即恢复直连，无残留全局网络规则。
- 忽略列表只按主机名匹配，不支持 IP 段 / 正则。
