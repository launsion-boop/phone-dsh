# Golden vectors — phone-dsh-v1

These files are the interoperability oracle for the Swift and TypeScript codecs. Each frame vector
is an independent example: `seq` and `mseq` values from different files are not one connection
history and MUST NOT be replayed as a stream.

## 1. Frame vector shape

Every `golden/frames/<type-name>-<n>.json` is a JSON object with exactly these members:

```json
{"type":"VFS_ACK","type_byte":17,"seq":3,"fields":{"level":1,"upto_mseq":45},
 "payload_hex":"01000000000000002d","frame_hex":"5a4c110000000000000000030000000901000000000000002d"}
```

- `type` — frame name from channel.md §2; `type_byte` — its `u8`.
- `seq` — the u64 written into the 16-byte header (channel.md §1). HELLO uses 1.
- `fields` — the semantic payload. For a JSON payload frame `fields` is the JSON object and is
  encoded as canonical JSON (channel.md §5). For a binary payload frame `fields` follows §3 below.
- `payload_hex` — lowercase hex of the bytes after the 16-byte header.
- `frame_hex` — lowercase hex of header + payload, i.e. the 16-byte header followed by
  `payload_hex`.

A conforming encoder MUST reproduce `payload_hex` and `frame_hex` byte-for-byte from `fields` and
`seq`. A conforming decoder MUST accept `frame_hex` and produce an equivalent `fields` value; member
order and whitespace are not significant for JSON frames, but the decoded bytes are.

## 2. Binary fields (`*_hex`)

Binary members are lowercase hex strings:

| Member | Where | Bytes |
|---|---|---|
| `data_hex` | VFS_MUT `fields` | raw mutation data; may be non-UTF-8 |
| `body_hex` | API_REQ / API_RES `fields` | raw request or response body; empty string means zero bytes |
| `record_hex` | JOURNAL `fields` | opaque tool-journal record bytes |
| `record_hex` | WAL `records[]` (later task) | complete WAL record `len ‖ crc32c ‖ mseq ‖ body` |
| `boot_id_hex` | WAL `header` (later task) | the raw 16 bytes of the WAL `boot_id` |

HELLO carries `boot_id` as the 32-character lowercase hex string of D6, not as `*_hex` bytes.
`fields.data_len` is present for VFS_MUT and MUST equal the decoded `data_hex` length.

## 3. Binary field tables

| Type | `fields` members |
|---|---|
| VFS_MUT | `mseq`, `op`, `mode`, `mflags`, `append_from`, `path`, `data_len`, `data_hex` |
| VFS_ACK | `level`, `upto_mseq` |
| VFS_BARRIER | `want_level`, `upto_mseq` |
| VFS_RESYNC | `path` |
| JOURNAL | `jseq`, `session_id`, `record_hex` |
| JOURNAL_ACK | `level`, `session_id`, `upto_jseq` |
| API_REQ | `req_id`, `head` (JSON object), `body_hex` |
| API_RES | `req_id`, `head` (JSON object on the first chunk, `null` when `head_len = 0`), `body_hex` |
| API_END | `req_id` |
| API_ABORT | `req_id`, `reason` (the string inside `{"reason":...}`) |

JSON payload frames (`HELLO`, `EXEC_REQ`, `EXEC_EVT`, `EXEC_CTL`, `LIFECYCLE`, `CONSOLE`, `FENCE`,
`ERROR`) store the whole payload object in `fields` and are validated against `schema/` where a
schema exists. `EXEC_EVT` is one exec-bridge v1 NDJSON event object; `exec_id` is a member of the
event, not a separate binary prefix.

## 4. Required variants

- `hello-host-1.json` and `hello-worker-1.json` cover both HELLO variants.
- `error-1.json` — a closing protocol ERROR; `error-2.json` — the non-closing `VFS_REFUSED`
  diagnostic with `path`/`limit`/`reason` (channel.md §4.8, §10); `error-3.json` — the host-side
  refusal form of the same frame, with `ref_seq` naming the refused VFS_MUT and structured `mseq`
  and `accepted_bytes` members.
- `vfs-mut-append-1.json` — appended write with `append_from > 0` and the appended bit set.
- `vfs-mut-binary-1.json` — write whose `data_hex` is not valid UTF-8.
- `vfs-mut-remove-1.json` — `op = 3`; `vfs-mut-chmod-1.json` — `op = 4`.
- `api-res-continuation-1.json` — `head = null`, i.e. `head_len = 0`.
- `api-res-empty-body-1.json` — first chunk with a head and a zero-length body.
- `console-2.json` carries literal non-ASCII UTF-8, pinning the no-`\u`-escape rule.
- `exec-req-1.json` includes `requires_mseq`, the two D10 keys and a real `idem_key` value
  (`env_hash` is the lowercase sha256 of the canonical JSON of the `env` object, as fixed by
  exec.md; this vector only pins the wire bytes).

`tools/spec_golden.py` asserts that every type byte has a vector and that these variants exist.

## 5. WAL vectors

`golden/wal/<name>.json` carries `header` (fields plus `header_hex`), `records[]` (each with
`kind`, `fields`, `crc32c` and `record_hex`) and `file_hex` = `header_hex` followed by every
`record_hex`. Mutation record bytes are `len u32 ‖ crc32c u32 ‖ mseq u64 ‖ mutation body without
mseq`; the epoch-close record is `op 0xFF` with `mseq = durable_upto`. The checker validates these
files when they exist; `--full` makes them mandatory.

## 6. Canonical JSON

JSON payload vectors are stored in canonical form (channel.md §5): UTF-8, no insignificant
whitespace, member names sorted by Unicode code point, `/` unescaped, integers only, no duplicate
members. The checker re-encodes `fields` canonically and compares the result with `payload_hex`;
a different member order or extra whitespace in the stored payload is a failure even when the JSON
is semantically equal.
