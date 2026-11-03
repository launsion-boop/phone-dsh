# ADR-4：区分 Personal Agent 委派与 DSH 直接写入

- 日期：2026-11-03
- 状态：已决定，待实现验收

## 背景

`PhoneToolBridge.callTool` 不携带调用方身份，而全局连接器需要同时服务 Personal Agent、L3 委派和用户直接在 DSH 发起的任务。

## 决定

- `.personalAgent(mandate)`：按 WorkMandate 和 grant 自动执行。
- `.delegatedDSH(mandateToken)`：使用绑定单个 Mandate、短时有效的 token，目标仍受 Mandate 限制。
- `.dshDirect`：只读默认放行，写入必须进入 DSH 逐项审批，不继承 Chat 的自动 grant。

全局 grant 是必要条件，不是跨路径的自动授权。DSH 独立 session 复用同一 ConnectorRegistry 和客户端，不复制 token 或连接状态。

## 后果

- 同一工具实现可以共享，但写权限语义不会因调用路径混淆。
- token 只限定范围，不扩大权限；泄露也不能越过 Mandate 的目标集合。

## 验证

- DSH 直接写入出现逐项审批。
- 委派 token 过期、越界和重放被拒。
- 两个 DSH session 复用同一连接而无需重新配置。
