<!-- SPDX-License-Identifier: MIT -->

# PC-20261116-bot-discover-measurement — eval-only DISCOVER 可观察性修正（冻结）

## 0. 摘要（機器可讀）

```yaml
change: PC-20261116-bot-discover-measurement
contracts: [P26]
status: frozen
breaking: false
version_decision: eval-only catalog change. No product/wire/schema change. The AHA-DISCOVER task text now names the output path `reports/weekly.md` in both arms (it still never names the guideline, OWNER or the risk heading); assertions check that one delivered file. Old results are kept but marked with the old observability caveat.
base: 908d582b9ee91886ba197bebd54b863c8093cced
contract_revision: freeze commit on aha/integration-20261116 (SHA in CONTRACT-FREEZE.md)
```

## 1. 问题（root 独立复核）

旧 AHA-DISCOVER 断言用两个 `workspace_command`：`grep *.md '^OWNER: 林$'` 与 `grep *.md '^## 风险'`。
不成立之处：
1. 用户没有指定文件输出或标题级别；guide 只要求“风险”段，`## 风险` 是过强测量；
2. `show_document` 的 inline content 或完整回复是合法交付，会被错判；
3. 两个 grep 可分别命中不同文件，不能证明同一交付物合规；
4. 没有排除 input guide/archive/工具读回结果。

因此旧的“DISCOVER 真实失败”不能作为最终依据；r8 的有/无必须用同一修正口径重跑，公平 baseline
若已通过且 r8 无增益，则撤回 r8。

## 2. 冻結的 eval-only 修正（最小方案）

`scripts/evals/bot-aha/aha_catalog.json` 的 `AHA-DISCOVER`：

- **两臂相同的第 2 条用户消息**（只在结尾加入输出路径；仍不点名规范/OWNER/风险）：
  > 先写这周的。本周完成了登录改造和两个 bug 修复，下周计划做导出。周四前要交给林。
  > 把这周成品保存为 `reports/weekly.md`。
- **断言（全部只针对 `reports/weekly.md` 同一个文件）**：
  1. `workspace_command`：`test -f reports/weekly.md`
  2. `workspace_command`：`grep -q '^OWNER: 林$' reports/weekly.md`
  3. `workspace_command`：`grep -Eq '^#{1,6}[[:space:]]*.*风险' reports/weekly.md`
     （任何标题级别含“风险”都算；不强制 `##`）
  4. `reply_not_contains`：`OLD_GUIDE_9C1`
  5. `reply_not_contains`：`周报-{`
- 断言不再扫描 `*.md`，因此 input guide/archive/工具读回不会被当成交付物；两个 grep 只针对同一文件。
- 不加新断言类型、不改 harness、不改产品代码。

## 3. 重跑与判定

- 两臂（control 无 r8 = `67022bc4a`；treatment 有 r8 = `67c4fd991`）各自重建 Worker image，
  用同一修正 catalog/dimensions、`--upstream real --repeat 2` 跑 `AHA-DISCOVER`；
  treatment 另跑 `AHA-INJECTION` 确认不退步。
- 判定：treatment DISCOVER PASS 且 INJECTION 不退步 → 保留 r8；否则撤回 r8。
- 若公平 baseline 在修正口径下已 PASS，而 r8 无增益 → 即使 treatment PASS 也撤回 r8。
- 旧结果保留并注明“旧 catalog 可观察性缺陷，不可比较”。

## 4. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| r1 | C | root 复核发现旧 DISCOVER 测量偏差；改为单一 `reports/weekly.md` + 语义风险段 | E、Q、R |
