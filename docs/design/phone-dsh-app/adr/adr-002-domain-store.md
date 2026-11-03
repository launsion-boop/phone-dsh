# ADR-2：Personal Agent 使用单文件 DomainStore

- 日期：2026-11-03
- 状态：已决定，待实现验收

## 背景

主对话、Memory、FollowUp、Mandate、操作账本和连接器游标需要跨进程恢复，DailyBrief 的原子 JSON 不适合无界任务数据。

## 决定

使用系统 `libsqlite3`，在 Application Support 的 Personal Agent 目录保存单个 `domain.sqlite`，启用 WAL 和单个 actor 串行写。文件使用 `NSFileProtectionCompleteUntilFirstUserAuthentication`。迁移按 owner/version 登记，表前缀按模块隔离。

DomainStore 是任务相关逻辑记录的统一权威，但不替代 DSH session 日志、ArtifactStore 字节或 Keychain。数据库损坏进入只读诊断，不静默删除重建。

## 后果

- 所有外部状态都能以事务恢复，UI 不保存第二份任务终态。
- 需要显式迁移、损坏处理、配额与后续保留策略。
- 不用 `node:sqlite` 或新增第三方 Swift 依赖。

## 验证

- 多 owner 迁移顺序、重复登记幂等和越权建表拒绝。
- 写事务中杀进程后恢复，未完成回合从记录重推导。
- 损坏数据库不自动删除，个人页可诊断。
