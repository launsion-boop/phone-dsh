# phone-dsh-v1 — host/worker protocol specification

Status: W1 contract, protocol `proto 1`, MIT.

The **host** is the iOS/macOS app process. The **worker** is DeepSeek Harness running unmodified
inside a WKWebView from the official webworker-runtime. The App owns the authoritative services;
the Worker owns the in-memory VFS.

```
WKWebView page ── one loopback HTTP origin ── App process (Swift host)
      │  static files, image, /v1/http, /v1/handoff/*
      └── one ordered binary WebSocket ──► VFS mutations · exec · journal · remote API
```

This directory fixes the byte-level contract between the two. It contains no DSH source and no DSH
patch. DSH is consumed only from its pinned checkout (0.2.1-rc.2, commit `7be5505`). iOS and WebKit
behaviour is **NOT_VERIFIED** until measured on a device; this document only fixes the wire contract.

Binary fields are big-endian (network byte order) everywhere. CRC32C is Castagnoli (reflected
polynomial `0x82F63B78`, init and xorout `0xFFFFFFFF`; known answer
`crc32c(b"123456789") == 0xE3069283`). JSON payloads use the canonical form of
[channel.md](channel.md) §5.

## 1. Terminology

| Term | Meaning |
|---|---|
| host | App process. Single authority: allocates `mseq`, owns the WAL, materialized VFS, journal, exec ledger, step records, fence, lease and admission. |
| worker | DSH webworker-runtime in the WebView. Owns the in-memory VFS, emits sink mutations, journal records, exec requests and API responses. |
| seq | Frame sequence **per WebSocket connection and per direction**: first frame 1, then +1 per frame. Not persistent, not replayed across connections, not an application idempotency key. |
| mseq | Host-allocated, persistent, strictly consecutive VFS mutation sequence. Survives reconnects, WebContent restarts and epochs; leads every VFS_MUT body and every WAL mutation record. `last_mseq` (D17) is the never-reused high-water mark. |
| jseq | Per-session journal sequence assigned by the worker, consecutive from 1, deduplicated by `(session_id, jseq)`. |
| epoch | Durability window of the WAL, closed by an epoch-close record and `F_FULLFSYNC`. The only point where ack level 2 is emitted. |
| fence | Execution authority token `{owner, generation u64, wal_seq u64}`. `generation` is monotonic and is the handoff CAS value. |
| idem_key | Exec idempotency key of [exec.md](exec.md) §1: 64 lowercase hex characters derived from the tool-journal key, canonical argv, cwd and env hash. |
| reclaim_token | 128-bit secret returned by a successful fence CAS. It is the only credential required to reclaim work from a remote host. |

## 2. Protocol version

- `proto` is the integer `1`. A HELLO with another value is `PROTO_MISMATCH` and the connection
  closes.
- The header layout, the 18 type bytes, every payload layout and every semantic rule are fixed for
  proto 1. New frame types, flag bits or required members need a new major protocol (new WebSocket
  subprotocol or origin path).
- JSON encoders emit canonical JSON ([channel.md](channel.md) §5). JSON decoders MUST accept any
  legal JSON object; member order, whitespace and escapes need not be canonical. Encoders MUST NOT
  emit members outside the schema; decoders MAY ignore unknown members.
- Capability sets are exchanged in HELLO: worker `["channel/1","vfs-sink/1","journal/1","api/1"]`,
  host `["channel/1","wal/1","exec/1","accelerator:<name>",...]`. A capability that is absent is
  not used.

## 3. File map

| File | Contents | State |
|---|---|---|
| [README.md](README.md) | Overview, terminology, proto 1, file map, decisions. | landed |
| [channel.md](channel.md) | 16-byte header, all 18 frame types, connection life cycle, VFS flow, reconnect, canonical JSON, identifiers, error codes. | landed |
| [wal.md](wal.md) | WAL segments, epochs, write path, materialized copy, manifest, reconcile, overlay, quotas, recovery. | landed |
| [exec.md](exec.md) | Two idempotency keys, dedup and replay, executor inversion, step machine, MCP header. | landed |
| [handoff.md](handoff.md) | Fence token, admission, handoff order, reclaim token, applier rules, endpoint bodies. | landed |
| [budgets.md](budgets.md) | Host state machine, transition table, driving signals, budget constants. | landed |
| [schema/hello.schema.json](schema/hello.schema.json) | HELLO host/worker variants (`oneOf`). | landed |
| [schema/exec-req.schema.json](schema/exec-req.schema.json) | EXEC_REQ JSON. | landed |
| [schema/exec-ctl.schema.json](schema/exec-ctl.schema.json) | EXEC_CTL JSON. | landed |
| [schema/lifecycle.schema.json](schema/lifecycle.schema.json) | LIFECYCLE JSON. | landed |
| [schema/fence.schema.json](schema/fence.schema.json) | FENCE JSON. | landed |
| [schema/error.schema.json](schema/error.schema.json) | ERROR JSON. | landed |
| [schema/console.schema.json](schema/console.schema.json) | CONSOLE JSON. | landed |
| [schema/api-request-head.schema.json](schema/api-request-head.schema.json) | API_REQ head JSON. | landed |
| [schema/api-response-head.schema.json](schema/api-response-head.schema.json) | API_RES head JSON. | landed |
| [schema/manifest.schema.json](schema/manifest.schema.json) | `manifest.json` of the WAL (D17 `last_mseq`). | landed |
| [schema/handoff-fence-request.schema.json](schema/handoff-fence-request.schema.json) | `/v1/handoff/fence` request. | landed |
| [schema/handoff-fence-response.schema.json](schema/handoff-fence-response.schema.json) | `/v1/handoff/fence` response. | landed |
| [schema/handoff-snapshot-request.schema.json](schema/handoff-snapshot-request.schema.json) | `/v1/handoff/snapshot` metadata. | landed |
| [schema/handoff-snapshot-response.schema.json](schema/handoff-snapshot-response.schema.json) | `/v1/handoff/snapshot` response. | landed |
| [schema/handoff-segments-request.schema.json](schema/handoff-segments-request.schema.json) | `/v1/handoff/segments` metadata. | landed |
| [schema/handoff-segments-response.schema.json](schema/handoff-segments-response.schema.json) | `/v1/handoff/segments` response. | landed |
| [schema/handoff-reclaim-request.schema.json](schema/handoff-reclaim-request.schema.json) | `/v1/handoff/reclaim` request. | landed |
| [schema/handoff-reclaim-response.schema.json](schema/handoff-reclaim-response.schema.json) | `/v1/handoff/reclaim` metadata. | landed |
| [schema/handoff-error.schema.json](schema/handoff-error.schema.json) | Handoff error envelope. | landed |
| [golden/README.md](golden/README.md) | Golden vector format and `*_hex` convention. | landed |
| `golden/frames/<type-name>-<n>.json` | One frame each: `{type, type_byte, seq, fields, payload_hex, frame_hex}`. | landed |
| `golden/wal/<name>.json` | Complete WAL segments: header, records, `file_hex`. | landed |
| [tools/spec_golden.py](tools/spec_golden.py) | Independent encoder and conformance checker (Python standard library only). | landed |
| [tools/test_spec_golden.py](tools/test_spec_golden.py) | Mutation tests for the checker. | landed |
| [tools/test_handoff_budgets.py](tools/test_handoff_budgets.py) | Mutation tests for the handoff schemas, the caps and the D14–D16 references. | landed |

`--full` additionally requires `wal.md`, `exec.md`, `handoff.md`, `budgets.md`,
`schema/manifest.schema.json` and the `golden/wal` vectors, and checks that the documents still
contain the byte-level contract text, the handoff schemas and the D14–D16 implementing
section references. The normal check validates WAL vectors, the manifest schema and every present
schema whenever they are present.

## 4. Decisions (D1–D20)

The numbered decisions are final. Each row quotes the decision wording verbatim from PLAN §2
(Markdown emphasis on the decision label is not repeated; PLAN §2 is the normative Chinese text, so
the quotations are Chinese, not a translation). Where a later decision amends an earlier one, the
amendment is named in the row. A backslash-escaped pipe in the D4 row is the markdown escape for the
literal `|` of its path grammar. Every row names the implementing file and section; a sentence that
disagrees with a row is a defect.

| # | Decision (verbatim) | Implemented in |
|---|---|---|
| D1 | seq 只是连接内的顺序校验。 每条 WebSocket 连接两个方向各自从 1 开始、每帧 +1，第一帧必是 HELLO（seq = 1）；收到 seq ≠ 期望值即 `0x7F BAD_SEQ` 并关闭。seq 不跨连接、不重放、不做应用层幂等。 | channel.md §1, §7 |
| D2 | 应用层幂等各有各的键。 VFS 变更靠 `mseq`（见 D3）；journal 记录靠 `(session_id, jseq)`；exec 靠 `idem_key`；远程 API 请求靠 `req_id`，重连后由发起方（Swift）重新发起，host 不重发 API_REQ，不维护重发环。 | channel.md §8, §9; exec.md §2 |
| D3 | mseq 由宿主分配、全局持久、严格连续。 host 的 HELLO 带 `next_mseq`（= WAL 尾 + 1）与 `acked_mseq`；worker 从 `next_mseq` 起为每条 VFS_MUT 连续编号。重连后 worker 用新连接重发所有 `mseq > acked_mseq` 的 VFS_MUT（保留原 mseq）；host 只接受 mseq == 期望值的变更，其它 `BAD_MSEQ`。worker 侧未确认变更缓冲上限 32 MiB：达到上限即**等待 ack（流控）**，等待超过 30 s 才 fail loud 关准入。 *(This decision predates D17, which amends the formula to `next_mseq = max(last_mseq, WAL tail) + 1`.)* | channel.md §4.1, §8, §9; wal.md §7.2 |
| D4 | sink 只发 `/dsh/home/**` 与 `/dsh/workspace/**`。 `/dsh/tmp/**` 与其它根不发送、不持久化（tmp 是易失的，重启后为空）。路径语法 `^/dsh/(home\|workspace)(/[^/]+)+$`，分量不得为 `.`、`..`、空；`/dsh`、`/dsh/home`、`/dsh/workspace` 本身不是合法变更目标；单个文件 ≤ 15 MiB（超出 VFS 侧 `EFBIG`；帧载荷上限 16 MiB，因此一条整文件 write 总能装进一帧）。因为 tmp 变更根本不发送，mseq 序列没有空洞。 *(Amended by the large-file budget revision of budgets.md §6: the single-file cap now follows the host `single_file_limit` and the §4 tier table — 64 / 48 / 32 / 16 MiB, host-configurable up to 128 MiB — and the 15 MiB value above survives only as the per-mutation VFS_MUT bound of channel.md §6.)* | budgets.md §4, §6; channel.md §6, §8 |
| D5 | 规范化 JSON 用于所有 JSON 载荷：UTF-8、无多余空白、键按码点排序、不转义斜杠、只用整数、无重复键。金标中的 JSON 帧 hex 是规范化形式；解码方须接受任意合法 JSON。二进制字段在金标里写成 `*_hex`。 | channel.md §5 |
| D6 | 标识符语法。 `exec_id`、`session_id`、`workspace_id`、`req_id`（字符串形式）匹配 `^[A-Za-z0-9._-]{1,64}$`；`boot_id` 为 32 位小写 hex；宿主把任何标识符用于路径前必须校验。 | channel.md §6 |
| D7 | 纪元关闭记录 `op 0xFF`，体 = `wall_ms u64` · `durable_upto u64`；它的 mseq 字段 = durable_upto = 关闭时刻全局最大已写入 mseq（与段无关，可小于本段 first_mseq）；不是变更、不推进 materialized_upto。`first_mseq` = 段创建时的 next_mseq（段内第一条变更将获得的 mseq），只含纪元记录的段也如此。纪元：每 30–60 s、进后台、交接前、计划内重启前关闭一次，对本纪元内写过的**每个**段 fd 做 `F_FULLFSYNC`，再 fsync 目录；ack level 2 只在此时发出。level 1 的承诺是"进程被杀不丢"（页缓存）；掉电最多丢最后一个纪元，那时 Worker 内存也已丢失、无可重发，tool-journal 能看出缺了哪些步。 | wal.md §4 |
| D8 | 结构校验 → WAL 追加 → ack → 物化；水位严格连续。 host 收到 VFS_MUT 只做结构校验（D4 路径与范围、mseq == 期望值、长度上限、mode/op 合法）；通过即 append 进 WAL 并 ack level 1——WAL 忠实记录 VFS 发生过的每条变更；再按 mseq 顺序应用到物化副本。`materialized_upto_mseq` 是**严格连续水位**：只有 ≤ 它的全部变更都已应用才推进。物化时 appended 变更基底不符（不满足 D9 两种情形）说明宿主副本与 WAL 流失配：host 立即发 0x13 VFS_RESYNC（Worker 的内存 VFS 在存活期间是权威），Worker 以下一个 mseq 发整文件 write；水位停在失配变更之前，直到该路径的整文件 write 应用后越过它；若到下一次纪元关闭仍未收到修复（Worker 已死或不回应）→ 状态机进 Failed，启动时做全树对账。manifest 不持久化 needs-resync 集合。结构校验失败才是协议错误：`BAD_PATH`/`BAD_MSEQ`/`BAD_PAYLOAD` 关闭连接。物化 I/O 失败是宿主缺陷 → Failed（fail loud）。 | channel.md §8; wal.md §5.1, §5.2 |
| D9 | appended 重放幂等：当前大小 == append_from → 追加；当前大小 ≥ append_from + data_len 且区间 [append_from, append_from + data_len) 的字节等于 data → 已应用，跳过（多条连续 append 重放也成立）；其它 → 按 D8 发 VFS_RESYNC 并停住水位。 | wal.md §6.2; channel.md §8 |
| D10 | 两个键并存。 现有 `XL_IDEMPOTENCY_KEY`（tool-journal 产生的 `xl1-<32hex>`）**不变**，继续注入命令环境；`idem_key = sha256(XL_IDEMPOTENCY_KEY ‖ 0x1F ‖ 规范化 argv JSON ‖ 0x1F ‖ cwd ‖ 0x1F ‖ env_hash)` 小写 hex，缺 XL_IDEMPOTENCY_KEY 时用 `session_id ‖ 0x1F ‖ turn_id ‖ 0x1F ‖ step_id` 代替首段。宿主去重表持久化；同 idem_key 直接回放已记录事件，不再执行；冲突检测只比较 argv 与 cwd（deadline、grace 等传输字段不参与）；`grace_ms` 按 exec-bridge v1 ≥ 1。MCP 调用带 `Idempotency-Key` 头。 | exec.md §1, §2 |
| D11 | 顺序纪律（D11）：恢复时**扫描 wal/ 目录**而不只看 manifest.segments（manifest 的段列表只服务于截断）：目录里有而 manifest 没列的段照常重放；manifest 列出但缺失的段，若其全部 mseq ≤ materialized_upto 则静默剔除，否则 `WAL_CORRUPT` → Failed。截断先改 manifest（去掉待删段并 fsync）再删文件；WAL 尾 < materialized_upto 是截断后的合法状态。全树对账：先写 `reconcile.inprogress` 标记，在 `materialized.staging/` 重建，rename 交换，最后改 manifest、删标记；启动时见到标记即重做对账。对账只在 manifest 与 WAL 尾不一致、或标记存在时进行，且**以物化副本 + WAL 尾**为输入，从不"只用 WAL 重建"。manifest 缺失而 WAL 存在：若最早段的 first_mseq == 1 则从空树重放全部 WAL 重建并写 manifest；否则（曾截断）→ Failed，需 Worker 重新给出全量快照。 | wal.md §7.2 |
| D12 | 执行器倒置。 `bash -c` 与所有会写工作区的命令留在 Worker（官方 runtime 的 JS shell；后期 Wasm brush / just-bash）；只有 host HELLO caps 里 `accelerator:<name>` 列出的只读命令（`rg`、`jaq`、`ts-parse`、`ts-query`、`phone`、`ctx`）经 0x20 外送；`exit` 不带变更清单。 | exec.md §3 |
| D13 | 步状态机由宿主观察、宿主持久化。 七步 `model_streaming → tool_dispatched → exec_running → exit_persisted → checkpoint_applied → wal_written → journaled` 记录在 `Library/xl/<workspace_id>/steps/`（只有 App 写），依据是 JOURNAL 帧（tool-journal 的 dispatched / completed 记录）与 EXEC 帧；Worker 内执行的 `bash -c` 只经历 `tool_dispatched → wal_written → journaled` 三步；`exit_persisted`、`checkpoint_applied` 只对宿主执行的加速器存在。tool-journal 幂等键定位到步。 *(Amended by the G2-FIX-93 terminal-owner revision, exec.md §4: the seven progress states above are unchanged; a step the host gives up after a Worker termination, failed drain, or planned Worker restart gets the additional terminal state `abandoned` with `settled_reason`. It is not a tool result, it produces no completed evidence, and it can never return to `journaled`.)* | exec.md §4 |
| D14 | 迁移表必须含：`Running → Recovering`（计划内重启 / WebContent 终止，仍在前台）、`Draining → Recovering`（重启路径）、`Draining → Parked`（进后台）、`Parked → Recovering`（scenePhase active）、启动时持久化状态为 `Running`/`Draining`/`Recovering` 一律进 `Recovering`、`Recovering → Running`（租约验毕、准入开）、`Running → Backoff → Running`、`Running/Draining → HandingOff → Remote`、`Remote → Reclaiming → Recovering`、任何状态 → `Failed`。 | budgets.md §1, §2 |
| D15 | 交接与回收。 所有 `/v1/handoff/*` 走 TLS 并带远端的 Bearer 凭据（与 DSH Remote 相同），fence CAS 另需 `expected_generation` = 当前。顺序：`/v1/handoff/fence`（成功后远端持 generation+1，手机拿到 128 位 `reclaim_token`）→ `/v1/handoff/snapshot`（全量 tar，响应带基底 `materialized_upto_mseq` 与 `fence.wal_seq`）→ `/v1/handoff/segments`（WAL 段，必须连续覆盖 (基底, wal_seq]，mseq 无空洞）→ 远端仅当已应用 mseq == fence.wal_seq 才开准入。回收：手机 `POST /v1/handoff/reclaim {reclaim_token}`（**不要求当前 generation**），远端排空、关闭纪元、回传新段与新栅栏 `{owner: phone, generation: 远端 generation + 1}`；回收幂等：远端按 reclaim_token 缓存回应 24 h，重复请求得到同一回应，只有持无效 token 才 401。远端应用器对 ≤ 其已应用 mseq 的段静默跳过。 | handoff.md §2–§5 |
| D16 | 文档纪律。 规范各文件都给上限：channel.md ≤ 350 行、wal.md ≤ 320、exec.md ≤ 220、handoff.md ≤ 200、budgets.md ≤ 200；README 必须有一张"Decisions"表逐条引用 D1–D20 并给出所在小节（规范只引用、不改写决策文字；觉得决策有误就在最终消息里说，不要改表）；任何与 D1–D20 冲突的句子视为缺陷。 | README §4; tools/spec_golden.py |
| D17 | mseq 永不复用。 manifest 记 `last_mseq`（已分配的最大 mseq）；`next_mseq = max(last_mseq, WAL 尾) + 1`，截断后亦然。 | wal.md §7; channel.md §4.1 |
| D18 | 纪元关闭的 fsync 顺序：先 fsync 本纪元内物化副本改动过的文件与目录（含 chmod 的父目录），再 F_FULLFSYNC 本纪元写过的全部 WAL 段，再原子写 manifest 并 fsync；可删段 = 全部 mseq ≤ materialized_upto 且其纪元已按此顺序关闭；截断只在纪元关闭之后进行。 | wal.md §5.2 |
| D19 | 损坏分级：尾部残缺记录（len/crc 不完整或不匹配，且其后无完整记录）→ 截断到最后一条完整记录并记日志，不是错误（只会在掉电后出现，掉电本就允许丢最后一个纪元）；非尾部的 CRC 失败 → `WAL_CORRUPT` → Failed。 | wal.md §10 |
| D20 | exec 字段约定：`step_id` = 本轮内工具调用的十进制序号（从 1 起）；`turn_id`、`session_id` 来自 DSH 会话；D10 的回退键首段 = `session_id ‖ 0x1F ‖ turn_id ‖ 0x1F ‖ step_id`。EXEC_REQ 里 `confine` 沿用 exec-bridge v1 的取值（`workspace-write` 等）并由 host 校验与 hello 能力一致；加速器本身只读由 ExecProvider 保证，规范不得因 `confine: workspace-write` 拒绝请求。`model_streaming` 属于轮次而非单个工具调用：bash -c 步只记 `tool_dispatched → wal_written → journaled`。 | exec.md §1, §3, §4; channel.md §4.2 |

## 5. Conformance

The files under [golden/](golden/) are the interoperability oracle. `tools/spec_golden.py` re-encodes
every frame vector from its semantic `fields` with an implementation independent of the Swift and
TypeScript codecs, checks canonical JSON, CRC32C, the JSON Schemas, the D1–D20 decision coverage,
documentation coverage, the D16 caps and that the D14–D16 rows of the Decisions table name existing
sections, validates the handoff endpoint schemas with their field lists, validates every
`golden/wal` vector and the manifest schema, and prints one line per checked file. `--full` makes
the WAL, exec, handoff and budgets documents, the manifest schema and the WAL vectors mandatory. A
conformance implementation MUST reproduce every `payload_hex` and `frame_hex` byte-for-byte, read
every WAL vector byte-for-byte, and accept the JSON variants shown.

Run:

```
python3 spec/v1/tools/spec_golden.py --full
python3 -m unittest discover -s spec/v1/tools -p 'test_*.py'
```
