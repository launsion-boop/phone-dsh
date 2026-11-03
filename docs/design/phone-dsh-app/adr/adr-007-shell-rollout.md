# ADR-7：legacy/v4 灰度与回滚

- 日期：2026-11-03
- 状态：已决定，待实现验收

## 背景

四入口外壳会改变 RootView、锚点、Composer inset、preview 和设置入口，导航回归需要可回退路径。

## 决定

提供 `PDSH_SHELL=legacy|v4`（launch argument + UserDefaults）。DEBUG 默认 v4；legacy 保留基线行为。任一时刻、任一工作区只挂载一个 active 外壳，不能同时运行两套控制器。

## 后果

- M1a 可对照截图和回归，失败可回到 legacy 定位。
- M4 验收后由用户决定何时删除 legacy，不在本期自动删除。
- 不以回滚开关掩盖新旧两套状态权威。

## 验证

- legacy 与基线行为一致。
- v4 切换不重启 Worker、不丢 DSH session 或草稿。
- 外壳回滚不产生第二个 Worker/anchor。
