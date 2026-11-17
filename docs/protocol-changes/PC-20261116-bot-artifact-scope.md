# PC-20261116-bot-artifact-scope — 跨 Bot artifact 内部 key

- status: frozen
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- owning contract: `spec/bot/v2/provenance.md` §3.5（G-1 r15）
- 无 schema/wire 变更；无持久字段/迁移；复用 `event.principal.botId` + path scope。

## Delta

内部 artifact key = `(owner_scope, kind, id, version?)`：
- `user/` memory/review → `shared`；`agent/` → `bot(<principal.botId>)`；
- `skill` → `host`（lineage 全局，session/event 仍隔离）；
- routine/proactive/notification/delivery/suggestion/draft → `bot(<principal.botId>)`；
- principal 缺失 → `unknown`，不得 shared。

所有查询（trace/reverseTrace/currentState/sourceStatuses/invalidation/audit）使用同一 key；baseline 按
`(artifact key, ref, role)` 查找，不按全局 ref 覆盖；erasure/grant/invalidation/upstream/source_statuses
同一过滤。缺省 owner 只能由宿主从已认领 session 填，不能默认 shared。

## 4 反例映射（Q1/root）

1. **material 无 baseline**：仍按 artifact key 查 baseline；缺失 → `unknown/no-baseline`，不借用其他
   Bot/其他 artifact 的 baseline。
2. **跨 Bot 同 path 碰撞**：Bot A/B 的 `agent/x.md` 为两个 key；A 的写/删/失效不影响 B；`user/x.md`
   为同一 shared key。
3. **同 ref 多 baseline 覆写**：baseline key 含 artifact key + role；同一 record ref 被两个 artifact
   引用时各自保留，不后者覆盖前者。
4. **skill 失效被 same 抹掉**：skill key=host；文件 same 不得覆盖 source erased/revoked/upstream
   （G-4 r2）；删除→unavailable/skill-deleted。

## 兼容/分工

- 旧事件/旧库无需迁移；owner 读时推导；旧 reader 不受影响。
- L：把上述 key 贯穿所有查询与索引；Q1 用 `reviews/repro/` 四个反例复验固定 fixSHA。
- R/P/C：material、cross-bot shared read、source_statuses 合并用同一 key；不得只修单查询。
- 未做：L 代码/Q1 复验/真实 runtime；本契约不替代。
