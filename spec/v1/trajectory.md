# Trajectory and UiState normalization — phone-dsh-v1

Status: P0 contract, MIT. This file is the **single** normalization oracle for two artifacts:

- `trajectory/1` — ordered Harness event rows (one JSON object per JSONL line);
- `ui-state/1` — rows projected from those events into the UI state tree.

Both use the same five ordered stages and the same stage-3 rule table. The tool
[tools/trajectory_norm.py](tools/trajectory_norm.py) is the executable copy; a schema is normative only
for shape, never for noise removal. Normative words: MUST, MUST NOT, SHOULD.

The goal is the pre-condition of §4.1 item 6 and §9.3: two platforms that observed the same logical
sequence, with different platform noise, produce **byte-identical** normalized JSONL. A real semantic
difference MUST survive normalization; it is never repaired by a noise rule.

## 1. Pipeline and invariants

| Stage | Name | Input | Output |
| --- | --- | --- | --- |
| 1 | strip domain | raw rows | rows without host-scoped values |
| 2 | ordering window | unordered rows | rows in one deterministic total order |
| 3 | platform noise whitelist | ordered rows | text with platform noise replaced |
| 4 | numeric normalization | rows | one canonical number per value |
| 5 | output form | rows | canonical JSONL bytes |

Invariants: the stages run exactly once, in this order; every algorithm below is total over valid input
or raises `NormError`; no stage compares two platform files; no stage guesses a missing event. The
normalized output is a pure function of `(rows, rule table, platform)`.

## 2. Stage 1 — strip domain

For every row, at every object depth, remove these members (case-sensitive): `time`, `timestamp`,
`wallClock`, `wallMs`, `occurredAt`, `mono`, `monotonic`, `monotonicMs`, `machAbsolute`,
`mach_absolute_time`, `uptimeMs`, `pid`, `processID`, `processId`, `port`, `socketPort`, `localPort`,
`remotePort`, `memory`, `memoryBytes`, `memoryMB`, `rssBytes`, `cpu`, `cpuPercent`, `cpuTimeMs`.
Rationale: wall-clock and monotonic clocks, process ids, ephemeral socket ports, and scheduler samples
differ on every run and carry no product semantics.

Rows whose `type` is one of `metric/sample`, `perf/sample`, `debug/clock`, `host/heartbeat` are dropped
whole (`droppedLines`). `platform` is captured for stage 3 and removed from the output.

**Absolute path prefix.** Apply these prefix rewrites to every string value, then validate path-member
values (`path`, `cwd`, `workspace`, `root`, `filePath`, `target`):

1. `(?:/private)?/var/mobile/Containers/Data/Application/<component>/(Documents|Library|tmp)/(workspace|home|tmp)` → `/dsh/<root>`
2. `/data/(user/0|data)/<component>/files/(workspace|home|tmp)` → `/dsh/<root>`

The suffix after the matched root is kept. A path MUST then be either `/dsh/{home,workspace,tmp}` or a
child of it, with non-empty segments and no `.`, `..`, NUL, or `//`; otherwise the row fails
(`UNPORTABLE_PATH`). Relative paths are kept as POSIX-normalized relatives. Already portable `/dsh/...`
paths pass unchanged.

**Random request-id suffix.** A `requestId`, `request_id`, or `reqId` value is reduced to its stable
stem by removing one trailing `[-_:]<6..32 hex>` or `[-_:]<6..20 digits>` group. A value that becomes
empty, is a UUID, or is 8..64 hex characters alone is removed. The stem itself is kept verbatim.

## 3. Stage 2 — ordering window

Group rows by `(sessionID, turnID)`; order groups by those two strings in Unicode code-point order.
Inside a group, the stable order key is `(seq, arrivalIndex)`; the global total key is
`(sessionID, turnID, seq, arrivalIndex)`. `seq` MUST be unique within the group; a duplicate fails (`DUPLICATE_SEQ`).

The tolerance window is `W = 16`. For each row in arrival order, `lateBy` is the count of rows already
seen in the same group whose `seq` is **strictly greater**. If any `lateBy > W`, normalization fails
(`OUT_OF_WINDOW`) instead of silently reordering a stream that cannot be trusted. A full reversal of at
most 17 rows is therefore accepted; a longer stream must arrive in order. `arrivalIndex` is only a
tie-breaker and never changes a byte when `seq` is unique.

## 4. Stage 3 — platform noise whitelist

The table is machine-readable in `RULES` in the tool and mirrored here. Rules apply in ascending `id`
code-point order, to string values below `data` (trajectory) or below `text`/`props` (UiState); ids,
types and keys are never rewritten. A rule applies only when its `platforms` contains `both` or the
row's captured platform. Each rule is regex + replacement, global substitution.

| id | platforms | pattern | replacement | reason |
| --- | --- | --- | --- | --- |
| `android-java-frame` | android | `(?m)^[ \t]+at [A-Za-z0-9_.$]+\([A-Za-z0-9_.]+\.(?:java\|kt):\d+\)[ \t\r]*(?:\n)?` | empty | JVM stack frames are runtime-specific |
| `android-thread-tag` | android | `\bthread=(?:main\|RenderThread\|DefaultDispatcher-worker-\d+)\b` | `thread=<worker>` | thread names are scheduler detail |
| `both-crlf` | both | `\r\n?` | `\n` | line endings are an encoding detail |
| `both-embedded-utc` | both | `\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\b` | `<timestamp>` | a wall clock embedded in text |
| `both-loopback-port` | both | `\b(?:127\.0\.0\.1\|localhost\|\[::1\]):\d{2,5}\b` | `loopback:<port>` | ephemeral loopback port |
| `both-pid-tag` | both | `\bpid[=:]\d+\b` | `pid=<removed>` | process id in a log line |
| `both-uuid` | both | `(?<!Application/)\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b` | `<uuid>` | install/run-scoped identifier |
| `ios-container-uuid` | ios | `/var/mobile/Containers/Data/Application/[0-9A-Fa-f-]{36}\b` | `/app-container` | container UUID changes per install |
| `ios-mach-time` | ios | `\bmach_absolute_time=\d+\b` | `mach_absolute_time=<removed>` | monotonic clock in a log line |

A rule whose pattern matches the empty string is rejected. The table is capped at **12** rules. Any
new rule needs a fixture that fails before it and passes after it, and a `reason` that names a platform
mechanism, not a symptom.

## 5. Stage 4 — numeric normalization

| Kind | Member names | Algorithm |
| --- | --- | --- |
| generic float | all other numbers | round half-even to 6 decimal places; `-0` → `0`; an integral result becomes a JSON integer |
| duration | `durationMs`, `elapsedMs`, `latencyMs`, `ttftMs`, `turnDurationMs`, `toolDurationMs` | round half-even to the nearest 10 ms, emit integer |
| byte count | `bytes`, `sizeBytes`, `bytesIn`, `bytesOut`, `payloadBytes`, `contentBytes` | parse `<number><space?><B\|KiB\|MiB\|GiB>` (1 KiB = 1024) and emit integer bytes, half-even |
| ratio | `percent`, `ratio` | round half-even to 3 decimal places |

Integer input stays integer except for duration members, which are quantized. `NaN` and infinities are
rejected by the JSON parser. The algorithm is decimal, not binary-float, so both languages can match it.

## 6. Stage 5 — output form

- One object per line, JSONL, UTF-8, `\n` between lines and exactly one `\n` after the last line;
  empty input produces empty output (zero bytes).
- Member names sorted by Unicode code point; no insignificant whitespace (`separators=(",", ":")`);
  `/` unescaped; non-ASCII literal; integers and finite numbers only; duplicate members rejected.
- The byte sequence is the assertion. A platform that differs only by trailing newline, member order,
  `1` vs `1.0`, or `-0.0` vs `0` is normalized to the same bytes.

## 7. UiState sequence sub-spec

A UiState sequence is a flat pre-order projection of the tree; `parentID` reconstructs the edges.
`nodeID` grammar (structural nodes use `seq = 0`; event nodes use the Harness `seq`):

```text
root
session/<sessionID>
session/<sessionID>/turn/<turnID>
session/<sessionID>/turn/<turnID>/event/<seq>
session/<sessionID>/turn/<turnID>/event/<seq>/<slot>
```

`<slot>` is `[a-z][a-z0-9-]{0,63}` and names a semantic role (`assistant-block-0`, `tool-call`,
`turn-end`), never an absolute path, UUID, or random hex run. Every `nodeID` is globally unique; every
`parentID` names an existing node and is exactly one grammar level above its child; the session and
turn segments MUST equal the row's `sessionID`/`turnID`. A row that violates this fails
(`UNSTABLE_NODE_ID`).

Allowed members are exactly: `schemaVersion` (`ui-state/1`), `platform`, `sessionID`, `turnID`, `seq`,
`nodeID`, `parentID`, `kind`, `surface`, `text`, `props`. Geometry, colors, frames and screenshots are
**not** members. `kind` is one of `root`, `session`, `turn`, `turn-event`, `bubble`, `context`,
`tool-row`, `thinking-pill`, `approval-card`, `composer`, `fail-loud-banner`, `status`; `surface` is
`none` or one of the six signature surfaces.
A `context` node carries an **injected** block (a file read, an approval, a command result folded into the prompt),
never a user message; `props.source` names the injector, and `unknown` (no source reported) reads as a user message.

Ordering reuses stage 2 with the same `W = 16` and key `(sessionID, turnID, seq, nodeID)`; `seq` may
repeat across sibling nodes, `nodeID` breaks the tie. Same noise rules, same numeric stages, same
canonical output.

**Semantic vs pixel.** Equality of normalized UiState sequences is the acceptance test. It is
*semantic*: text, state, membership, order and parentage must match. *Pixel* equality is required only
for the six signature surfaces — `bubble`, `tool-row`, `thinking-pill`, `approval-card`, `composer`,
`fail-loud-banner` — and is judged from a separate screenshot artifact, never from this JSONL. All
other nodes (`root`, `session`, `turn`, `status`, …) are semantic-only. A normalized sequence MUST NOT
be used to assert geometry.

## 8. Reverse re-evaluation triggers (§8.3 signal ①)

The route is re-estimated, not patched, when any of these holds:

1. the whitelist reaches the cap of 12 rules, or a thirteenth rule is proposed;
2. more than 3 rules are added in any rolling 30-day window (25% of the cap), or more than 2 per month
   for two consecutive months;
3. after normalization, more than 1 in 20 golden scenarios still needs a hand-written exception, or a
   semantic-difference fixture needs a new noise rule to pass;
4. a platform change alters a stage-1 domain or stage-2 key rather than a stage-3 rule.

When triggered, stop adding rules, record the residual diffs, and take §8.3 signal ① (2-month format
stability gate) to the route review. Threshold numbers are in `RULE_CAP` and
`RULE_GROWTH_LIMIT` in the tool so CI can print them.

## 9. Conformance and golden layout

`spec/v1/golden/trajectory/<case>/` holds `ios.jsonl`, `android.jsonl`, `notes.json`, `expected.jsonl`,
and, only for a declared `real-difference` case, one platform-specific expected file whose bytes differ
from `expected.jsonl`. `notes.json.kind` is `equivalent` or `real-difference`; the latter MUST justify
why the difference is semantic and MUST map the two expected files. `--check-golden` asserts:

- every input and expected line validates against its schema;
- `normalize(ios) == normalize(android) == expected` for `equivalent`;
- `normalize(ios) == expected` and `normalize(android) == the platform-specific expected`, and the two
  differ for `real-difference` — proving the tool never washes a semantic difference away;
- every case normalizes identically twice (deterministic self-check).

CLI: `--input F --output F [--root R]`, `--check-golden --root .`, `--stats`. The pure core is
`normalize(lines, rules) -> lines`; it is importable and has no I/O except schema loading. The
`--input` path normalizes twice and fails if the two byte sequences differ, so determinism is checked
on every run rather than only in tests.
