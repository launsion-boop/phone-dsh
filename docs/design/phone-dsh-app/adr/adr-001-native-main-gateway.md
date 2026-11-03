# ADR-1：原生 Main 使用独立网关实例

- 日期：2026-11-03
- 状态：已决定，待实现验收

## 背景

Personal Agent 的 L1/L2 不应为普通问答和秒级 API 读取启动第二个 DSH 引擎。`ModelGateway` 只提供请求转发、SSE 字节、重试、凭据和响应日志，不提供模型协议。

## 决定

在 App 组合根创建独立于 Worker 生命周期的 `ModelGateway`。Provider 配置和 Keychain 读取复用现有实现，响应日志放在 Personal Agent 独立目录，模型上游 allow-list 与连接器网络权限分开。原生 Main 自己实现 Anthropic Messages 请求构造、SSE 解析、tool-call loop 和上下文压缩。

首版仅支持 Anthropic Messages。其他 Provider 在 Chat 显示“暂不支持该协议，可改用 DSH”，不静默换协议或启动第二个 WebKit。

## 后果

- 需要新增一个轻量 runtime 工作包，不能按“复用网关已完成”估算。
- 组合根必须保证 DSH 宿主与 Personal Agent 的网关实例、日志和生命周期互不共享。
- `PhoneDSHGateway` 当前公开构造与请求 API 足够时，不修改 SDK。

## 验证

- 非 Anthropic Provider 返回 `.unsupportedProtocol`。
- 回合中没有创建 WKWebView 或第二个 DSH session。
- Anthropic SSE 分片、取消、tool-call 回环和首字延迟有测试及测量记录。
