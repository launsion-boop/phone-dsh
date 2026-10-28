# channel.md — ordered channel (phone-dsh-v1, proto 1)

Status: normative. One binary WebSocket carries VFS mutations, exec, journal, remote API and control
frames. Text messages are a protocol error. There are no zero-length payloads. All binary integers are big-endian.
## 1. Header (16 bytes)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 2 | `magic` | `u16 = 0x5A4C` |
| 2 | 1 | `type` | `u8`, §2 |
| 3 | 1 | `flags` | `u8 = 0`; every other value is `BAD_PAYLOAD` |
| 4 | 8 | `seq` | `u64`, per connection and per direction; first frame 1, then +1 per frame |
| 12 | 4 | `len` | `u32`, payload length; `1 ≤ len ≤ 16 MiB` |

`magic` mismatch is `BAD_MAGIC`. A non-zero flag, `len = 0` or `len > 16 MiB` is `BAD_PAYLOAD`.
The hand-computed header of a `0x11` frame with `seq = 1` and `len = 9` is
`5a4c1100000000000000000100000009`. A magic mismatch and every header failure close the connection;
`seq` rules are §7.
## 2. Frame types

| Type | Name | Direction | Payload |
|---|---|---|---|
| `0x01` | HELLO | both | JSON, §4.1 |
| `0x10` | VFS_MUT | worker → host | binary, §3.1 |
| `0x11` | VFS_ACK | host → worker | binary, §3.2 |
| `0x12` | VFS_BARRIER | worker → host | binary, §3.3 |
| `0x13` | VFS_RESYNC | host → worker | binary, §3.4 |
| `0x20` | EXEC_REQ | worker → host | JSON, §4.2 |
| `0x21` | EXEC_EVT | host → worker | JSON, §4.3 |
| `0x22` | EXEC_CTL | worker → host | JSON, §4.4 |
| `0x30` | JOURNAL | worker → host | binary, §3.5 |
| `0x31` | JOURNAL_ACK | host → worker | binary, §3.6 |
| `0x40` | API_REQ | host → worker | binary, §3.7 |
| `0x41` | API_RES | worker → host | binary, §3.8 |
| `0x42` | API_END | worker → host | binary, §3.9 |
| `0x43` | API_ABORT | both | binary, §3.10 |
| `0x50` | LIFECYCLE | host → worker | JSON, §4.5 |
| `0x60` | CONSOLE | worker → host | JSON, §4.6 |
| `0x70` | FENCE | host → worker | JSON, §4.7 |
| `0x7F` | ERROR | both | JSON, §4.8 |

An unknown type byte is `BAD_PAYLOAD`; a known type in the wrong direction is `PROTO_MISMATCH`; both close.
## 3. Binary payloads
### 3.1 VFS_MUT (`0x10`, worker → host)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 8 | `mseq` | `u64 ≥ 1`, host-allocated, §8 |
| 8 | 1 | `op` | `u8`: 1 write, 2 mkdir, 3 remove, 4 chmod |
| 9 | 4 | `mode` | `u32` permission bits `≤ 0o7777` for write/mkdir/chmod; 0 for remove |
| 13 | 1 | `mflags` | `u8`: bit0 `entryChanged`, bit1 `appended`; bits 2–7 are 0 |
| 14 | 8 | `append_from` | `u64`; only with bit1 `appended`, otherwise 0 |
| 22 | 2 | `path_len` | `u16`, byte length of `path` |
| 24 | `path_len` | `path` | UTF-8 absolute path, §6 |
| `24+path_len` | 4 | `data_len` | `u32`, byte length of `data` |
| `28+path_len` | `data_len` | `data` | raw bytes; empty for mkdir/remove/chmod |

`appended` means `data` is the file suffix starting at byte offset `append_from`; `append_from` may
be 0. A complete write has bit1 clear and `append_from = 0`. mkdir/remove/chmod carry no data,
`mflags = 0` and `append_from = 0`. `op = 1` data is at most 15 MiB (`EFBIG` above, no VFS_MUT is
sent); a file larger than one mutation is one complete write followed by appended suffixes (§6).
### 3.2 VFS_ACK (`0x11`, host → worker)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 1 | `level` | `u8`: 1 = WAL `write()` returned; 2 = epoch `F_FULLFSYNC` done |
| 1 | 8 | `upto_mseq` | `u64`, highest contiguous mseq covered |

Acks are cumulative and may coalesce (host group commit: 2 ms). Level 2 is sent only by an epoch close, for the highest mseq in that epoch.
### 3.3 VFS_BARRIER (`0x12`, worker → host)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 1 | `want_level` | `u8`, 1 or 2 |
| 1 | 8 | `upto_mseq` | `u64` |

Sent at tool-call boundaries and before backgrounding. The host answers with a VFS_ACK at
`want_level` for `upto_mseq` once that level is reached. A barrier never reorders or blocks other
frames.
### 3.4 VFS_RESYNC (`0x13`, host → worker)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 2 | `path_len` | `u16` |
| 2 | `path_len` | `path` | UTF-8 absolute path, §6 |

Asks for a complete re-send of `path` after an appended mutation could not be materialized. It is not a protocol error and neither reuses nor skips an mseq: the worker answers with a complete `op = 1` write at the **next mseq** and, for a file larger than one mutation, the appended suffix chain at the following mseqs (§3.1, §8); one resync per path, duplicates idempotent.
### 3.5 JOURNAL (`0x30`, worker → host)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 8 | `jseq` | `u64 ≥ 1`, per `session_id`, consecutive from 1 |
| 8 | 2 | `session_id_len` | `u16` |
| 10 | `session_id_len` | `session_id` | UTF-8, §6 |
| `10+session_id_len` | rest | `record` | opaque tool-journal record bytes, at least 1 byte |

The host appends the record and deduplicates by `(session_id, jseq)`. A jseq at or below the
highest appended value is a duplicate and is ignored; a forward gap is `BAD_PAYLOAD`.
### 3.6 JOURNAL_ACK (`0x31`, host → worker)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 1 | `level` | `u8`: 1 = journal `write()` returned; 2 = journal fsync |
| 1 | 2 | `session_id_len` | `u16` |
| 3 | `session_id_len` | `session_id` | UTF-8, §6 |
| `3+session_id_len` | 8 | `upto_jseq` | `u64`, highest contiguous jseq |
### 3.7 API_REQ (`0x40`, host → worker)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 4 | `req_id` | `u32`, unique among in-flight requests of this connection |
| 4 | 4 | `head_len` | `u32 > 0` |
| 8 | `head_len` | `head` | JSON `{method, path, headers}`, §4.9 |
| `8+head_len` | rest | `body` | raw request body, at most 4 MiB; may be empty |
### 3.8 API_RES (`0x41`, worker → host)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 4 | `req_id` | `u32` |
| 4 | 4 | `head_len` | `u32`; first chunk `> 0`, later chunks exactly 0 |
| 8 | `head_len` | `head` | JSON `{status, headers}` on the first chunk only |
| `8+head_len` | rest | `body` | raw response chunk; may be empty |
### 3.9 API_END (`0x42`, worker → host)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 4 | `req_id` | `u32`; `len = 4` exactly |

The response is complete.
### 3.10 API_ABORT (`0x43`, both)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 4 | `req_id` | `u32` |
| 4 | rest | `reason` | JSON `{"reason": <string>}`, §4.9 |

Terminates an in-flight request. The frame is idempotent after termination. When a connection dies, each side aborts its own in-flight requests with `{"reason":"connection_closed"}`; that frame is delivered to the local handler and is never written to the dead socket.
## 4. JSON payloads

All JSON payloads are canonical JSON (§5). Field tables are normative; matching schemas are in
`schema/`. Decoders MAY ignore unknown members.
### 4.1 HELLO (`0x01`, both)

| Field | Type | Host | Worker | Meaning |
|---|---|---|---|---|
| `proto` | integer | yes | yes | 1 |
| `role` | string | yes | yes | `"host"` or `"worker"` |
| `boot_id` | string | yes | yes | 32 lowercase hex characters, per process boot |
| `session_epoch` | integer | yes | yes | Host session incarnation; the worker echoes its boot value |
| `fence` | object | yes | yes | `{owner, generation, wal_seq}` |
| `caps` | array | yes | yes | Capability strings (below) |
| `next_mseq` | integer | yes | no | `max(last_mseq, WAL tail) + 1` (D17) |
| `acked_mseq` | integer | yes | no | Effective tail `max(last_mseq, WAL tail)`; highest level-1-acked mseq |
| `durable_mseq` | integer | yes | no | `durable_upto` of the last closed epoch |
| `last_mseq` | integer | no | yes | Highest mseq assigned by this worker process; 0 if none |

HELLO is the first frame of each direction with `seq = 1`; a later HELLO is `PROTO_MISMATCH`. The host sends `next_mseq = max(last_mseq, WAL tail) + 1` (D17); `last_mseq` is the manifest high-water and the WAL tail the highest retained mutation mseq.
`acked_mseq` is the effective tail, so a truncated WAL never reuses an mseq and `durable_mseq ≤ acked_mseq` holds.

**Fence object.** `{owner: string, generation: u64, wal_seq: u64}`. `owner` is 1–64 characters of `[A-Za-z0-9._:-]`; `generation` and `wal_seq` are non-negative integers.
The host rejects a worker HELLO whose `fence.generation` is below the host's current generation, or whose `owner` differs from the current owner, with `FENCE_STALE`, then closes.

**Capabilities.** Worker caps are exactly `["channel/1","vfs-sink/1","journal/1","api/1"]`. Host caps contain at least `channel/1`, `wal/1` and `exec/1`, plus zero or more read-only `accelerator:<name>` entries (names: `rg`, `jaq`, `ts-parse`, `ts-query`, `phone`, `ctx`).
A missing required capability is `PROTO_MISMATCH`. Other capability strings are reserved.
### 4.2 EXEC_REQ (`0x20`, worker → host)

The exec-bridge v1 `POST /v1/exec` request body plus two members:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `exec_id` | string | yes | D6 identifier |
| `argv` | array of strings | yes | Program and arguments; no shell parsing |
| `cwd` | string | yes | Absolute path visible to the worker |
| `env` | object | no | String values set, `null` unsets |
| `deadline` | integer | no | Unix epoch milliseconds |
| `grace_ms` | integer | no | 1–60000; absent means 3000 |
| `stdin` | object | no | `{mode}` = `ignore`, `data` (with `data` base64) or `pipe` |
| `tier` | string | no | `interactive`, `session` or `batch` |
| `confine` | object | no | `{mode, workspace_root}`; mode is `read-only` or `workspace-write` |
| `requires_mseq` | integer | yes | Apply VFS in memory through this mseq before dispatch; 0 = no dependency |
| `idem_key` | string | yes | 64 lowercase hex characters, exec.md §1 |

A repeated `idem_key` replays the recorded events instead of executing again (D10). While admission
is closed the host starts no execution and answers with a terminal `EXEC_EVT` `error` event.
### 4.3 EXEC_EVT (`0x21`, host → worker)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `type` | string | yes | `start`, `output`, `exit`, `quiescent` or `error` |
| `exec_id` | string | yes | D6 identifier of the execution |
| `seq` | integer | yes | Per-execution event sequence, from 0 |
| event fields | — | per type | exec-bridge v1 §4.1; `exit` is sent immediately and not coalesced |

The event object is canonical JSON and carries `exec_id`; there is no separate binary prefix.
### 4.4 EXEC_CTL (`0x22`, worker → host)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `exec_id` | string | yes | Target execution |
| `op` | string | yes | `cancel` or `stdin` |
| `data` | string | for `stdin` | Base64 stdin bytes |
### 4.5 LIFECYCLE (`0x50`, host → worker)

| Field | Type | Meaning |
|---|---|---|
| `state` | string | `run` (normal), `pause` (no new model request or tool dispatch; in-flight work continues), `stop` (refuse new work with a structured error so the turn ends) |
| `budget` | integer | Remaining execution budget in milliseconds, informational; 0 means none |
| `admission` | string | `open` or `closed` |
| `reason` | string | Machine-readable reason, e.g. `foreground`, `background` |

A new side effect needs both the last LIFECYCLE and the last FENCE admission to be `open`.
### 4.6 CONSOLE (`0x60`, worker → host)

| Field | Type | Meaning |
|---|---|---|
| `level` | string | `debug`, `info`, `warn` or `error` |
| `text` | string | Console line; the readiness marker `XL_DSH_READY` travels here |
### 4.7 FENCE (`0x70`, host → worker)

| Field | Type | Meaning |
|---|---|---|
| `fence` | object | New execution authority, §4.1 |
| `admission` | string | `open` or `closed` |

FENCE may advance the generation on a live connection. After the host's current generation exceeds
the HELLO generation, any side-effect frame from that worker (`VFS_MUT`, `EXEC_REQ`, `JOURNAL`,
`API_RES`, `API_END`) is `FENCE_STALE` and closes.
### 4.8 ERROR (`0x7F`, both)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `code` | string | yes | §10 |
| `message` | string | yes | Human-readable detail |
| `ref_seq` | integer | no | Seq of the offending frame |

For `code = VFS_REFUSED`, `path` (string), `limit` (integer bytes) and `reason` (`file-too-large`, `no-space` or `quota-exceeded`) are also required; it is a resource refusal, not a protocol error, the refused mutation consumed no mseq and the channel stays open. Either side may send it: the worker sink guard, or the host budget check for a mutation that would grow a file past `single_file_limit`. A host reply names the refused frame by `ref_seq` and carries the refused mutation's `mseq` and its accepted prefix `accepted_bytes` as structured integer members (`append_from` of an appended mutation, bounded by `limit`; 0 for a complete write; both are absent on a worker-sink refusal), so the Worker shrinks the mutation to `limit - accepted_bytes` and resends it with that same `mseq`; `message` is human-readable detail only.
Golden frame at `seq = 9` for `{"code":"VFS_REFUSED","limit":15728640,"message":"EFBIG","path":"/dsh/workspace/a","reason":"file-too-large"}`:
`payload_hex=7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d`
`frame_hex=5a4c7f0000000000000000090000006d7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d`
Host golden frame at `seq = 7` for a refused VFS_MUT at `ref_seq = 4` with structured `mseq = 5` and `accepted_bytes = 0` and the 64 MiB tier default: `golden/frames/error-3.json`.
### 4.9 API heads

API_REQ head: `{"method": string, "path": string, "headers": {lowercase-name: string}}`. `method` is an uppercase HTTP token; `path` starts with `/` and includes any query string.
API_RES head: `{"status": integer 100–599, "headers": {lowercase-name: string}}`. All header values are strings; duplicate response headers are joined by their owner.
## 5. Canonical JSON (D5)

A JSON payload is UTF-8 with no insignificant whitespace, member names sorted by Unicode code point, `/` never escaped, integers only (no fraction, exponent or `-0`), and no duplicate member name. Non-ASCII characters are emitted literally; `\"` and `\\` are escaped, control characters use `\b \f \n \r \t` or lowercase `\u00xx`. Example: `{"a":1,"b":["x","/y"]}`.

Goldens store this form (`payload_hex` of a JSON frame is canonical); decoders MUST accept any legal
JSON object, and a duplicate member, non-integer number or malformed JSON is `BAD_PAYLOAD`.
## 6. Identifiers, paths and sizes (D4, D6)

- `exec_id`, `session_id`, `workspace_id` and string-valued `req_id` match
  `^[A-Za-z0-9._-]{1,64}$`. `boot_id` is exactly 32 lowercase hex characters. On-wire API `req_id`
  is a `u32` and is not a D6 string; the D6 rule applies when a request id is used as a string.
- Mutation paths match `^/dsh/(home|workspace)(/[^/]+)+$`. No component is `.`, `..` or empty;
  `/dsh`, `/dsh/home` and `/dsh/workspace` are not mutation targets. `/dsh/tmp/**` and every other
  root are neither sent nor persisted. A violation is `BAD_PATH`.
- `/dsh/tmp/**` and `/tmp/**` are both writable, name one directory (the worker canonicalises `/tmp/**` onto
  `/dsh/tmp/**` before the VFS sees it), and are never sent or persisted. The entry seeds the root at boot and
  fails loud if the spellings diverge (the upstream sandbox grants `/tmp` and `os.tmpdir()` = `/dsh/tmp`); `/dev/null` is the only device.
- `/dsh/home/{sessions,storages,tool-journal}/**` is DSH-internal: execution surfaces (`bash`,
  `python3`, `git`) receive `EACCES` with a remediation line and never see the bytes.
- One file is at most the host's `single_file_limit`: the budgets.md tier default (64 / 48 / 32 / 16 MiB)
  or a configured value in 16 MiB ... 128 MiB, gated by the tier. One mutation carries at most 15 MiB
  (the 16 MiB frame cap leaves room for header and path); a larger file is one complete write plus
  appended suffixes whose `append_from` equals the accepted logical length, carrying only the suffix.
  The worker VFS refuses a post-write file above `single_file_limit` with `EFBIG` and emits no
  VFS_MUT (a `VFS_REFUSED` diagnostic may follow); the host rejects a `data_len` above 15 MiB
  with `BAD_PAYLOAD`, and a mutation that would grow a file past the limit (tracked from the WAL
  tail and the materialized copy) is answered with one `VFS_REFUSED` on the same connection and consumes no mseq.
- The host validates every identifier before using it in a filesystem path.
## 7. Connection life cycle

1. The loopback service authenticates the upgrade before this channel exists; rejected upgrades never reach the frame layer.
2. Each direction sends HELLO with `seq = 1` as its first frame. A first frame of another type is
   `PROTO_MISMATCH`; a first-frame HELLO at another seq is `BAD_SEQ`. Both close.
3. Each side validates `proto`, `role`, capabilities, identifier syntax and fence (§4.1); the host is the fence authority.
4. After HELLO, `seq` MUST equal the previous inbound seq + 1. A gap, duplicate or regression is
   `BAD_SEQ` and closes. A new connection starts a fresh seq space; no seq is carried over.
5. A frame whose type is unknown or is sent in the wrong direction is a protocol error (§2, §10).
6. While admission is closed the worker starts no new tool work and sends no new EXEC_REQ; the host
   starts none and answers one with a terminal `error`; flushing and in-flight work continue.
7. Sending a protocol ERROR closes the connection after the frame is flushed; `VFS_REFUSED` is a diagnostic and does not close (§4.8). A dead connection loses no acknowledged WAL or journal data; recovery is §9.
## 8. VFS flow (D3, D4, D8, D9)

- **Numbering.** The host allocates `mseq`; the worker uses HELLO `next_mseq`, then `+1` per mutation.
  Only `mseq == expected_mseq` is accepted (else `BAD_MSEQ`); `mseq` is independent of `seq`, survives reconnects and restarts.
- **Sink scope.** The sink emits only `/dsh/home/**` and `/dsh/workspace/**` (§6); `/dsh/tmp/**` and its `/tmp/**` spelling are volatile and never sent, so mseq has no holes.
- **Resource refusal is not structural.** A worker sink guard (`EFBIG`, `ENOSPC`, quota) sends one `ERROR VFS_REFUSED` with `path`/`limit`/`reason` plus a CONSOLE audit line, consumes no `mseq` and keeps the channel open; the Worker write prechecks turn the same condition into the command's own `EFBIG`, and only the `write` tool and other runtime writers reach the sink. A host budget refusal sends the same frame for a structurally valid mutation whose logical size would exceed `single_file_limit`: it appends nothing, leaves `expected_mseq` unchanged, records a diagnostic, and the Worker resends the same `mseq`; a later legal write or remove of the refused path clears the poisoned `flush()`. The host never treats either refusal as a connection error and does not enter Failed.
- **Structural validation only.** On VFS_MUT the host checks path and scope, `mseq`, lengths, `op`,
  `mode`, `mflags` and `append_from` consistency — never the data. A failure is `BAD_PATH`/`BAD_MSEQ`/`BAD_PAYLOAD`, close.
- **Write path (D8).** A structurally valid mutation is appended to the WAL as-is, acknowledged at
  level 1, and only then applied to the materialized copy. The WAL records every mutation the VFS
  committed; a result never suppresses the record. Level 1 survives a kill, not power loss (D18).
- **Base mismatch and repair (D8).** If an `appended` mutation's base does not match the materialized
  file (current size is neither `append_from`, a D9 replay, nor a torn prefix of the record), the host sends VFS_RESYNC at
  once and defers that path. The accepted record keeps its mseq; the worker replies with a complete
  `op = 1` write plus, for a larger file, the appended suffix chain at the next normal mseqs.
  `materialized_upto_mseq` is a strictly contiguous watermark: it waits below the mismatching mseq
  until the full write is applied and the path's pending appends settle. No resync state is persisted in the manifest; an unrepaired mismatch at
  the next epoch close enters Failed, and a boot re-encounters it during replay. Not a protocol
  error; a materialization I/O failure enters Failed and closes admission.
- **Idempotent append replay (D9).** During materialization the host appends when current size is
  `append_from`; it skips when size is at least `append_from + data_len` and the target byte range
  already equals `data`; it completes a torn write when the size is between `append_from` and
  `append_from + data_len` and the present prefix equals `data`'s prefix, appending only the missing
  suffix. Every other case is the base-mismatch path above. Consecutive append replays use this rule.
- **Flow control.** The worker buffers unacknowledged VFS_MUT payloads up to 32 MiB. At the limit it
  sends no further VFS_MUT and keeps reading; 32 MiB is a sliding window, not a per-file cap, so a
  64 MiB file is published across several level-1 acks. The 30 s fail-loud timer is an inactivity
  timer that starts only when the window is full: every level-1 ack that advances `acked_mseq`
  restarts it, so a slow but progressing publish never trips it; no progress for 30 s sends `RING_TIMEOUT`, closes admission and fails loud.
- **Barrier.** VFS_BARRIER requests level 1 (tool-call boundary) or level 2 (before background) for
  an `upto_mseq`; the host answers with the matching VFS_ACK when reached. Barriers do not block
  unrelated frames.
- **Ack level 2** is emitted only at an epoch close, after changed materialized files and directories
  are fsynced, every epoch segment is `F_FULLFSYNC`ed and the manifest is rewritten (D18); no other event sends it.
## 9. Reconnect (D2, D3)

A reconnect is a new WebSocket connection with fresh seq counters; nothing is replayed by seq.

1. Both sides send HELLO (seq 1): the host carries `next_mseq`, `acked_mseq`, `durable_mseq` and the current fence; the worker carries `last_mseq` and the fence it holds.
2. The worker waits for the host HELLO, then re-sends every VFS_MUT with `mseq > acked_mseq` in
   ascending mseq order, preserving the original mseq and body. The host accepts only
   `acked_mseq + 1` onward; a gap is `BAD_MSEQ`.
3. Journal records are re-sent per `(session_id, jseq)` above the highest jseq the host acknowledged;
   the host deduplicates by that pair.
4. API requests are re-issued by their owner with fresh `req_id`s. The host channel never replays
   API_REQ. Every request still in flight when a connection dies is aborted with
   API_ABORT `{"reason":"connection_closed"}` on the local side.
5. Exec requests are re-issued with the same `idem_key`; the host replays the recorded event stream
   for that key and does not execute again (D10).
6. A path still waiting for a resync is re-requested with VFS_RESYNC after HELLO (in-memory state; after a boot replay re-encounters the mismatch). Flow control resumes from the new `acked_mseq`.
## 10. Error codes

Every ERROR is flushed; every code except `VFS_REFUSED` then closes the connection. `ref_seq` names the offending frame.

| Code | Sent by and when | Closes |
|---|---|---|
| `BAD_MAGIC` | Either side: header magic is not `0x5A4C`. | yes |
| `BAD_SEQ` | Either side: inbound `seq` is not the exact next value. | yes |
| `BAD_MSEQ` | Host: VFS_MUT `mseq` is not the expected value. | yes |
| `BAD_PATH` | Host: VFS_MUT or VFS_RESYNC path violates §6. | yes |
| `BAD_PAYLOAD` | Either side: malformed payload, unknown type byte, non-zero flags, `len` outside 1..16 MiB, bad JSON, identifier, capability set, level or length field. | yes |
| `FENCE_STALE` | Host: HELLO fence generation is below the current generation or owner differs; or a side-effect frame arrives after the generation advanced. | yes |
| `VFS_CONFLICT` | Worker: a VFS_RESYNC cannot be answered because the path is no longer a regular file (removed or replaced by a directory). Terminal fail-loud. | yes |
| `VFS_REFUSED` | Either side: a mutation is refused for a resource limit — the Worker sink guard (`EFBIG`, `ENOSPC`, quota) or the host `single_file_limit` budget; carries `path`/`limit`/`reason` (a host reply also carries the refused `mseq` and `accepted_bytes`), consumes no mseq, and is a diagnostic. | no |
| `RING_TIMEOUT` | Worker: 32 MiB unacked and no ack progress for 30 s. Admission closes and the host enters Failed. | yes |
| `PROTO_MISMATCH` | Either side: HELLO `proto` is not 1, first frame is not HELLO, a second HELLO arrives, a known type is sent in the wrong direction, or a required capability is missing. | yes |
