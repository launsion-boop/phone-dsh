# PC-20261116-e7-freshness-reuse-fetch — E7 公开来源 freshness 复用现有 fetch

- status: frozen（无新端点/存储/wire）
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- owning: `spec/bot/v2/provenance.md` §4.5.1、`spec/bot/v2/context-sources.md` §4.1
- evidence: `evidence/cloud-freshness/run_freshness.py`、`freshness-http-chain.json`、`server.log`
  （SC 9/9 PASS，受控 upstream；identity/JWKS 是 stub，非生产互联网）

## Delta

- E7 的 web/connector recheck 复用现有 `POST /v1/web/fetch`（Bearer + 现有 target/allow-list/超时/
  size 约束），不新增端点、不新增存储、不新增 wire 字段。
- 归一化 content（换行/首尾空白）→ `sha256:` version；`observed_at` 取响应标准 `Date`（秒级；ms 可
  用接收时间但标来源）；identity=规范化请求 URL（redirect 最终 URL 不在现有响应，禁止声称）。
- 同 digest current/unchanged；不同 changed；401/403/私网拒绝 denied；5xx/超时/空 unavailable/
  not-performed；不得 current，不用旧正文冒充新鲜。
- 云 DB/log 不落正文/URL/凭据；手机只内存 hash/比较；写时基线仍按 G-1 持久化。
- SC 已修重复 Date 头（`fcec15a`），依赖 uvicorn 标准 Date。无新 cloud contract 包/manifest 变更。

## A09 语义（同一 commit 记录）

- 云执行前重查独立 opt-in + `authorization_ref` 可解析/未 erased；否则 refuse/cancel。
- 源读取/材料消费在使用处按 N consent generation/current grant 核验；撤权不读/不注入旧 observation。
- F suppression 只在 delivery 出口；不停 routine/不影响云调度；cross-goal 不误停。
- 只有从真实 `derivation.sources` 可解析的来源依赖才因撤权停/quiet routine；无依赖只查 cloud 授权，
  nil resolver 不算已验证；无新映射表/字段。

## 未做

- R 的 `CloudWebRecheckTransport`/P/L 真实接入、next-turn changed/unknown 证据；S/N/C 的 A09 语义
  实际证据（无授权不调度、撤云授权取消、撤来源不读旧、F 只交付）；E/root 判。E7 仍 OPEN，不能标 P2。
