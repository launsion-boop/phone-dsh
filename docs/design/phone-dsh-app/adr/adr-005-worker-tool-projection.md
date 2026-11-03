# ADR-5：按宿主宣告投影连接器工具到 Worker

- 日期：2026-11-03
- 状态：已决定，待实现验收

## 背景

当前 Worker 能力清单只发布 `phone info`，DSH 模型看不到 `github.*`。只在 Swift 注册工具桥不足以完成真实 DSH 联调。

## 决定

Worker 的 `phone` 段增加按宿主 HELLO 宣告生成的工具行：只有宿主宣告 `phone-tool:github.*` 等能力时，才发布对应 `phone github.* {...}`。未宣告时保持基线的 `phone info`。能力清单与原生桥实例必须来自同一组合根。

## 后果

- DSH 模型能发现真实工具，而非靠 prompt 猜测。
- 需要修改 TypeScript 能力清单、测试和 Worker bundle。
- 若宿主能力通道不能承载该宣告，停止该路线并评估 host-managed MCP，不伪造联调通过。

## 验证

- 未宣告时能力与基线一致，宣告后出现精确工具行。
- `capability-manifest.test.ts`、`phone-plugins` 和 `phone-bundle-fresh` 通过。
- 真实 DSH session 完成 GitHub 工具调用，另一 session 可复用。
