<!-- SPDX-License-Identifier: MIT -->

# Bot event store, effect outbox and user-action transaction (P25, SQLite v3)

Status: normative for the phoneDSH Bot durable store. Contracts: P25 (BotEventLog and
effects), P27 (the `BotUserAction` row model consumed by the transaction). Owning
implementation today: Swift `Sources/PhoneDSHBot/{Store,Journal}`. Contract revision:
`P25-store-v3` (PC-20261112-android-bot-w4, lane C2; the change record stays `status:
draft` until the contract owner merges this lane). A Kotlin port must produce and accept
the bytes and state transitions frozen here; static schema checks are not runtime
conformance.

This document does **not** define a new wire format. It freezes the SQLite file profile,
the stored event bytes, the durable sequence domain, the effect outbox state machine and
the single user-action transaction that already exist in Swift. `spec/bot/v1/README.md`
§1 remains the short index; when this document and that paragraph disagree, this document
is the detailed owner and the paragraph is corrected in the same change.

Normative keywords: **MUST**, **MUST NOT**, **SHOULD**. A rule marked *Swift detail* is
observable reference behaviour that a port may implement differently only where the
difference cannot be observed through the contract: file protection class, class/actor
names, the Swift error enum spelling, test-only crash hooks and the 250 ms App poll are
not contract values. Error **conditions** named below are normative; the spelling of the
Swift case that reports them is reference.

## 0. Scope and sequence domains

- The store owns **durable Bot events** and **durable effects**. The P03 journal
  (`jseq`) is a different sequence domain and MUST NOT be mixed with `commitSeq`
  (`spec/bot/v1/README.md` §1, `spec/README.md` §6.1).
- One SQLite database serves every Bot of the App. `botId` is a column/field, never a
  file per Bot (`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:510-514`; the Bot
  *VFS* root `BotWorkspaceLayout.botRoot` is a different tree and MUST NOT contain the
  database, `Sources/PhoneDSHBot/Attachments/BotWorkspaceLayout.swift:18-31`).
- Authentication, authorization and the P26 memory semantics are not defined here. The
  store validates the envelope shape and the P25 event identity rules; it does not decide
  whether a Bot may write memory or call a tool.

## 1. File location, names and permissions

The Bot data root is the App-private directory named `PhoneDSHBot`. Relative to it:

| Path | Meaning |
| --- | --- |
| `domain.sqlite` | the one database |
| `domain.sqlite-wal` | WAL sidecar while the connection is open |
| `domain.sqlite-shm` | shared-memory sidecar while the connection is open |

- **Normative.** The logical path is `<app-private support root>/PhoneDSHBot/domain.sqlite`.
  iOS builds it from `FileManager.applicationSupportDirectory` in
  `SQLiteDomainStore.applicationSupport()` (`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:510-514`);
  the App's profile files resolve the same `PhoneDSHBot` directory through
  `BotProfileStorage` (`examples/probe-app/PhoneDSHProbe/Bot/BotProfileStorage.swift:8-17`).
  Android MUST use its app-private files directory plus the same logical subtree
  `PhoneDSHBot/domain.sqlite` (the port plan records `Context.filesDir` as the root,
  `docs/design/android-bot-port-plan.md:1079`). No shared/external storage, no per-Bot
  database, no second file name.
- **Normative.** The database directory and the database and sidecar files MUST be
  readable and writable only by the App. On iOS the reference creates the directory as
  `0700` and each file as `0600`, and applies
  `FileProtectionType.completeUntilFirstUserAuthentication`
  (`SQLiteDomainStore.swift:54-62`, `:177-190`). The POSIX modes are normative where the
  host has POSIX permissions; the Apple protection class is *Swift/iOS detail*.
- A missing directory is created on first open. Deleting the database is a user-data
  erasure action, not a recovery action; the store never deletes or recreates it on a
  failed open.

## 2. Open sequence and pragmas

The reference opens with `sqlite3_open_v2(READWRITE | CREATE | FULLMUTEX)` and a 5,000 ms
busy timeout, then applies these pragmas in this order
(`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:64-114`):

| Step | Value | Normative |
| --- | --- | --- |
| `PRAGMA journal_mode=WAL` | result MUST be `wal`; otherwise open fails | yes |
| `PRAGMA synchronous=FULL` | `FULL` | yes |
| `PRAGMA foreign_keys=ON` | `ON`, re-applied after migration | yes |
| `PRAGMA secure_delete=ON` | `ON` | yes |
| `PRAGMA user_version` | read; `0` = new, `1`/`2` = migrate, `3` = current, `>3` = `schemaTooNew` | yes |
| `PRAGMA quick_check` | exactly one row whose value is `ok` | yes |
| `PRAGMA foreign_key_check` | empty (checked by the actor integrity scan after schema creation) | yes |

- A new database runs the v3 DDL (§3) and sets `PRAGMA user_version=3`.
- A v1/v2 database is migrated in place (§7). The migration temporarily disables
  `foreign_keys`; the reference re-enables it and runs `foreign_key_check` before the
  store is returned.
- `schemaTooNew` MUST be raised **before** any schema statement or write for
  `user_version > 3`; the file MUST be left untouched
  (`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:88-96`;
  `Tests/PhoneDSHBotTests/Store/UserActionTransactionTests.swift:77-89`).
- `synchronous=FULL` is a pragma of the profile, not a claim of tested power-loss
  durability. No repository test cuts power; see §13.
- *Swift detail.* The `FULLMUTEX` flag, the `SQLiteDomainStoreError` spelling and the
  mapping of SQLite errors to `corrupted` for `SQLITE_CORRUPT`/`SQLITE_NOTADB` are
  reference implementation choices. A port MUST expose equivalent open failures; the
  contract distinguishes `schemaTooNew`, `corrupted` and a generic SQLite failure.

## 3. Schema v3 (normative DDL)

The following is the exact DDL created by
`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:370-475`. Column names, types,
constraints, trigger names, the view name/columns and the index names are normative. A
reader MAY add indexes; it MUST NOT rename or drop a column, relax a constraint, drop a
trigger or change the view to a table. `CREATE TABLE IF NOT EXISTS` is used so opening an
existing v3 file is idempotent.

```sql
CREATE TABLE IF NOT EXISTS bot_event_headers (
    commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0),
    event_id TEXT NOT NULL UNIQUE,
    event_type TEXT NOT NULL,
    payload_digest TEXT NOT NULL,
    payload_size INTEGER NOT NULL CHECK (payload_size >= 0),
    header_meta BLOB NOT NULL
);
CREATE TRIGGER IF NOT EXISTS bot_event_headers_reject_update
BEFORE UPDATE ON bot_event_headers BEGIN
    SELECT RAISE(ABORT, 'bot_event_headers is append-only');
END;
CREATE TRIGGER IF NOT EXISTS bot_event_headers_reject_delete
BEFORE DELETE ON bot_event_headers BEGIN
    SELECT RAISE(ABORT, 'bot_event_headers is append-only');
END;
CREATE TABLE IF NOT EXISTS bot_event_payloads (
    commit_seq INTEGER PRIMARY KEY REFERENCES bot_event_headers(commit_seq),
    payload BLOB,
    erased_at INTEGER,
    erasure_commit_seq INTEGER REFERENCES bot_event_headers(commit_seq),
    CHECK ((payload IS NULL AND erased_at IS NOT NULL AND erasure_commit_seq IS NOT NULL)
           OR (payload IS NOT NULL AND erased_at IS NULL AND erasure_commit_seq IS NULL))
);
-- The payload table has exactly one legal mutation: the host erasure
-- path replaces the bytes with NULL and records the erasure event.
CREATE TRIGGER IF NOT EXISTS bot_event_payloads_erase_only
BEFORE UPDATE ON bot_event_payloads
WHEN NOT (OLD.payload IS NOT NULL AND NEW.payload IS NULL
          AND NEW.erased_at IS NOT NULL AND NEW.erasure_commit_seq IS NOT NULL)
BEGIN
    SELECT RAISE(ABORT, 'bot_event_payloads only supports erasure');
END;
CREATE TRIGGER IF NOT EXISTS bot_event_payloads_reject_delete
BEFORE DELETE ON bot_event_payloads BEGIN
    SELECT RAISE(ABORT, 'bot_event_payloads rows are never deleted');
END;
-- Read-only compatibility surface for readers written before the
-- v3 split. It reconstructs the old `bot_events.payload` shape from
-- the header and the separately stored payload; an erased event comes
-- back as a decodable envelope with the sentinel data object.
CREATE VIEW IF NOT EXISTS bot_events AS
SELECT h.commit_seq AS commit_seq,
       h.event_id AS event_id,
       h.event_type AS event_type,
       CAST(json_set(
           h.header_meta,
           '$.data',
           CASE WHEN p.payload IS NULL
                THEN json_object('$erased', json('true'),
                                 '$erasureCommitSeq', p.erasure_commit_seq)
                ELSE json(CAST(p.payload AS TEXT))
           END
       ) AS BLOB) AS payload
FROM bot_event_headers AS h
LEFT JOIN bot_event_payloads AS p ON p.commit_seq = h.commit_seq;
CREATE TABLE IF NOT EXISTS bot_effects (
    effect_key TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    operation TEXT NOT NULL,
    target TEXT NOT NULL,
    canonical_resource TEXT NOT NULL,
    args_digest TEXT NOT NULL,
    payload_digest TEXT NOT NULL,
    logical_key TEXT NOT NULL,
    idempotent INTEGER NOT NULL,
    retry_policy TEXT NOT NULL,
    max_attempts INTEGER NOT NULL CHECK (max_attempts > 0),
    generation INTEGER NOT NULL CHECK (generation > 0),
    not_before INTEGER,
    state TEXT NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    enqueued_commit_seq INTEGER,
    lease_owner TEXT,
    lease_expires_at INTEGER,
    started_at INTEGER,
    last_error TEXT,
    error_class TEXT,
    result_ref TEXT,
    applied_at INTEGER,
    reconciliation_reason TEXT,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS bot_effects_lease_candidates
ON bot_effects(state, not_before, enqueued_commit_seq, effect_key);
CREATE TABLE IF NOT EXISTS bot_effect_inbox (
    receiver TEXT NOT NULL,
    effect_key TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation > 0),
    attempt INTEGER NOT NULL CHECK (attempt > 0),
    applied_at INTEGER NOT NULL,
    result_ref TEXT,
    PRIMARY KEY(receiver, effect_key, generation)
);
CREATE INDEX IF NOT EXISTS bot_effect_inbox_lookup
ON bot_effect_inbox(receiver, effect_key, generation DESC);
CREATE TABLE IF NOT EXISTS bot_user_action_nonces (
    bot_id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    event_id TEXT NOT NULL UNIQUE REFERENCES bot_event_headers(event_id),
    created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0),
    PRIMARY KEY(bot_id, nonce)
);
```

Notes that are normative for readers:

- `bot_event_headers` is append-only. Both UPDATE and DELETE triggers abort. A writer
  MUST NOT try to change an event after it is committed; the only legal correction is a
  new event.
- `bot_event_payloads` MUST have exactly one row per committed header; a header with no
  payload row is corruption. The only legal UPDATE is the erasure transition described in
  §5.4; DELETE is never legal.
- The `bot_events` view MUST keep the historical four columns `commit_seq`, `event_id`,
  `event_type`, `payload`; `payload` is a BLOB containing the full envelope with `data`
  substituted. It is a read-only compatibility surface. It requires SQLite JSON1
  (`json_set`, `json_object`, `json`); a host whose SQLite lacks JSON1 MUST fail closed
  or add a JSON1-enabled SQLite rather than replace the view silently.
- `bot_user_action_nonces.event_id` is UNIQUE and references
  `bot_event_headers(event_id)`, not `commit_seq`. `created_commit_seq` is the sequence
  of that event. The primary key is `(bot_id, nonce)`; the same nonce for two Bots is
  two rows.
- `bot_effects.idempotent` is stored as `0`/`1`. `state` stores the strings in §9.1.
  `generation` is `>= 1`; `attempt`/`attempts` default to `0` and advance per §9.
- `bot_effect_inbox` is keyed by `(receiver, effect_key, generation)`; a newer
  generation may add a row, and the lookup reads the highest generation.

## 4. commitSeq assignment and event append

### 4.1 The sequence

- `commitSeq` is a positive integer assigned only by the store inside the writing
  transaction. The first durable event is `1`, and each subsequent durable event is
  exactly `previous + 1`. Durable batches are contiguous and atomic.
- The caller MUST NOT supply `commitSeq` on append. The codec rejects it with
  `COMMIT_SEQ_ASSIGNED_BY_STORE` in append mode
  (`Sources/PhoneDSHBot/Journal/BotEventEnvelopeCodec.swift:143-149`). Stored events MUST
  carry `commitSeq >= 1`; the stored-mode error is `MISSING_COMMIT_SEQ`
  (`BotEventEnvelopeCodec.swift:150-158`).
- Allocation is `MAX(commit_seq) + 1` inside `BEGIN IMMEDIATE`
  (`Sources/PhoneDSHBot/Journal/SQLiteDomainStore+BotEventLog.swift:256-280`). Two
  connections therefore serialize on SQLite's write lock; the busy timeout bounds the
  wait. A writer MUST NOT use a process-local counter as the authority.
- `commitSeq` is not reused after a rollback. A failed transaction leaves the previous
  head; the next committed event takes the next number. The store never renumbers.
- The ephemeral buffer (§6.4) never consumes a `commitSeq`.

### 4.2 Duplicate `eventId`

- `eventId` is the idempotency key. Its namespace is owned by the producing contract
  (§8). The store enforces only non-empty and global UNIQUE.
- Appending **one** event whose `eventId` already exists MUST return the already
  committed sequence and MUST NOT append a second row or compare payload bytes
  (`SQLiteDomainStore+BotEventLog.swift:220-234`;
  `Tests/PhoneDSHBotTests/Store/SQLiteDomainStoreTests.swift:18-38`). A producer MUST
  reuse an id bare only for the same logical event: a different payload under the same
  id is ignored, not merged.
- A durable batch MUST NOT contain an already committed `eventId`; the batch is rejected
  with `invalidTransition` and no row is written. A batch MUST NOT contain the same id
  twice; also `invalidTransition`.
- A user-action plan whose event `eventId` already exists is a different case: it MUST
  fail with `invalidTransition` and MUST NOT consume the nonce (§10.3).

### 4.3 Batches

- `appendBatch` requires at least one event and rejects ephemeral members with
  `invalidTransition` (`SQLiteDomainStore+BotEventLog.swift:22-35`).
- If every event carries no `batch`, the store assigns one batch id
  `batch:<lowercase uuid>` to the batch and fills `index` `0…n-1` and `total=n` for
  `n > 1`; a single event keeps `batch` absent.
- If all events carry a batch, the id MUST be identical, `index` MUST equal the
  event's position and `total` MUST equal the batch size. Mixing batched and unbatched
  events is `invalidTransition`. The batch references are part of the stored envelope.
- The whole batch is inserted in one transaction; a crash or error before `COMMIT` leaves
  none of it.

### 4.4 Reading

- `events(after:limit:)` requires `after >= 0`, `limit > 0`, and `after <= head`.
  A cursor ahead of the head is `invalidCursor`.
- Rows are returned in ascending `commit_seq`, starting at `after + 1`. Every returned
  row MUST have the expected next sequence; a gap inside the returned window is
  `commitGap(expected:actual:)` (`SQLiteDomainStore+BotEventLog.swift:37-70`).
- `headCommitSeq()` returns `0` for an empty store.
- `event(withId:)` returns the event or nil; it MUST NOT create one.

### 4.5 Envelope validation the store relies on

The store calls the codec in `.append` mode before every durable insert and on every
decode. The following are normative outcomes; the full envelope schema and presence
rules are `event-envelope.schema.json` and `spec/bot/v1/README.md` §1.2:

| Condition | Error code/condition |
| --- | --- |
| `schemaVersion > current` (1) | `SCHEMA_TOO_NEW` |
| `schemaVersion != 1` | `INVALID_EVENT` |
| empty `eventId`, `traceId`, `turnId`, `runId`, invalid principal kind/origin source, negative `time`, `attempt < 1`, invalid `batch`, `ignorable:false`, `data` not an object | `INVALID_EVENT` |
| ephemeral type with `commitSeq` | `EPHEMERAL_HAS_COMMIT_SEQ` |
| unknown type without `ignorable:true` | `UNKNOWN_REQUIRED_EVENT` |
| append-mode `commitSeq` present | `COMMIT_SEQ_ASSIGNED_BY_STORE` |
| stored-mode `commitSeq` missing | `MISSING_COMMIT_SEQ` |

`memory.document_written` and `memory.document_deleted` are **known durable types** for
this contract. They are listed by `BotEventEnvelopeCodec.durableEventTypes`
(`Sources/PhoneDSHBot/Journal/BotEventEnvelopeCodec.swift:27-48`) and by
`event-envelope.schema.json`; they are written with `origin = local/memory-service` and
`principal.kind` equal to the memory author's principal kind
(`Sources/PhoneDSHBot/Memory/SQLiteBotMemoryDocumentStore.swift:870-888`). Their `data`
is the memory-document write/delete object, not the envelope; it carries `path`, `scope`,
`version`, `expected_version`, `updated_at_ms`/`at`, `author`, `evidence` and optional
`trust`/`source` (`SQLiteBotMemoryDocumentStore.swift:10-44`). This repair records types
the Swift writer already produced; it does not change the bytes of existing rows.

## 5. Canonical stored bytes and payload digest

The v3 split stores the envelope metadata and the event `data` separately. There are
three byte surfaces; only the second is hashed.

### 5.1 `header_meta`

`header_meta` is the canonical JSON BLOB of the **full envelope with `data` replaced by an
empty object `{}`**, including the assigned `commitSeq`:

- UTF-8, object keys sorted, `/` not escaped, no insignificant whitespace;
- a member that is absent (nil) is omitted by the writer, per
  `spec/bot/v1/README.md` §1.2; readers accept absent and explicit `null` as the same
  value;
- `data` MUST be present and MUST be `{}` in the header. The real data lives only in
  `bot_event_payloads.payload`.

The reference writes it with `JSONEncoder` `[.sortedKeys, .withoutEscapingSlashes]`
(`BotEventEnvelopeCodec.swift:162-167`; `SQLiteDomainStore+BotEventLog.swift:260-273`).
`header_meta` is not itself hashed and MUST NOT be used to reconstruct erased data.

### 5.2 `bot_event_payloads.payload`

`payload` is the canonical JSON BLOB of the event's `data` object **only**:

- UTF-8; object keys sorted; `/` not escaped; compact separators; no trailing newline;
- numbers follow the JSON codec of the host but MUST round-trip the same JSON value;
  integral values that fit `Int64` are written without a fractional part;
- `data` MUST be an object; an array or scalar is `INVALID_EVENT` (`data`)
  (`BotEventEnvelopeCodec.swift:178-193`).

The canonical bytes are what cross-end replay and `payload_digest` cover. A producer that
cannot reproduce them MUST fail rather than store a second spelling of the same data.

### 5.3 `payload_digest` and `payload_size`

- `payload_digest` is the lowercase hexadecimal SHA-256 of exactly the `payload` bytes
  (`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:366-368`).
- `payload_size` is the byte length of exactly those bytes, `>= 0`.
- The digest is over `data`, **not** over `header_meta` and not over the old full
  envelope. The erasure path keeps both digest and size after clearing the payload, so
  the original bytes cannot be reconstructed and the fact of erasure remains auditable.
- A reader MUST recompute and compare both on open (§7); a mismatch is `corrupted`.

### 5.4 Erasure of a payload

The only legal mutation of `bot_event_payloads` is the host erasure path
(`SQLiteDomainStore+BotEventLog.swift:104-199`):

1. `erasureTargets(for:)` sorts and de-duplicates the requested sequences, requires each
   to exist, and reports `payloadBytes = 0` for an already erased event so a retried
   erasure is idempotent.
2. `erasePayloads` requires a durable `erasure` event and at least one target. Inside one
   transaction it appends the `erasure` event, then sets `payload = NULL`,
   `erased_at = atMS`, `erasure_commit_seq = <new sequence>` for every target with bytes.
   It verifies each update before `COMMIT`.
3. After the commit the reference runs `secureEraseStorage()`: `PRAGMA
   wal_checkpoint(TRUNCATE)`, `PRAGMA secure_delete=ON`, `VACUUM`,
   `wal_checkpoint(TRUNCATE)`, then reapplies file modes. This is outside the erasure
   transaction and MUST NOT be reported as part of the logical commit.
4. A read of an erased event returns the envelope with the sentinel data object
   `{"$erased":true,"$erasureCommitSeq":<n>}`; it MUST NOT return the original bytes.
   The header, `eventId`, `event_type`, digest and size stay.
5. `erasure_commit_seq` MUST reference a committed event whose type is exactly
   `erasure`, and it MUST be greater than the erased event's sequence. `erased_at` is an
   integer millisecond timestamp. A row with both payload and erasure markers, or with
   neither, is `corrupted`.
6. The legacy `bot_events` view MUST expose the same sentinel for erased rows; it MUST
   NOT fail to decode.

## 6. Appending and reading rules that are easy to get wrong

### 6.1 Origin, principal and type domains

The codec enforces closed sets for `principal.kind` (`chat`, `task`, `routine`,
`verifier`, `team`, `proactive`, `watchdog`, `maintainer`, `ipc`) and `origin.source`
(`ipc`, `card-bridge`, `mcp`, `scheduler`, `task-manager`, `memory-service`,
`comm-service`, `projector`, `effect-runner`, `runtime`, `user`, `watchdog`,
`background-supervisor`) (`BotEventEnvelopeCodec.swift:56-63`). An unknown value is
`INVALID_EVENT`; there is no "use a generic source" fallback.

### 6.2 Durable vs ephemeral

`BotEventEnvelopeCodec.durableEventTypes` and `ephemeralEventTypes` are the closed type
lists (`BotEventEnvelopeCodec.swift:27-54`); the schemas are
`event-envelope.schema.json` (durable-only) and `event-envelope.ephemeral.schema.json`
(no `commitSeq`). A type in neither list is unknown: it is accepted only with
`ignorable:true`, and an unknown non-ignorable type is `UNKNOWN_REQUIRED_EVENT`. An
unknown type with `ignorable:true` is stored like a durable event and consumes a
`commitSeq`; the flag skips its semantics, not its durability. There is no third
"accepted but not stored" class.

### 6.3 Event ID namespaces that are idempotency keys

The store does not parse prefixes. The following producer-owned namespaces are frozen
where the reference code constructs them; a replay of the same logical operation MUST
reuse the same id, and a new operation MUST NOT reuse it.

| Namespace | Producer / source |
| --- | --- |
| `evt:<lowercase uuid>` | effect transition events (`Journal/BotEffectOutbox.swift:533-545`) |
| `authz-snapshot-<lowercase uuid>` | grant snapshot (`Authz/BotGrantSnapshot.swift:149-163`) |
| `created:<taskId>` | task creation, written before work starts (`MCP/BotDSHRemoteRuntime.swift:576-590`) |
| `ledger.usage_recorded:<lowercase uuid>` | LLM ledger (`Ledger/BotLLMLedger.swift:8-13`) |
| `watchdog.flagged:<unitKind>:<unitId>:<check>` | watchdog; when the raw id exceeds 400 characters the unit id is replaced by the first 32 hex characters of its SHA-256 (`Watchdog/BotWatchdogMonitor.swift:325-332`) |
| `wake-inbox:<enqueue|stage|commit|revert|recover>:<key>` | held-inbox mutations (`Wake/WakeInbox.swift:240-314`) |
| `routine-snapshot:<runId>:<attempt>:<phase>` | routine durable snapshots (`Routines/RoutineMachine.swift:238-431`, `Routines/RoutineStore.swift:87`) |

`agent.comm` and task/routine event ids are owned by their producing contracts (P27 and
P26 respectively); their ids appear in the shared golden and are not re-defined here.
`wake-inbox` is owned by the v2 wake contract; the namespace is listed because it is an
idempotency key stored by this table.

### 6.4 Ephemeral ring

`append` of an ephemeral type validates the append envelope, appends to an in-memory
ring and returns `0` (`SQLiteDomainStore+BotEventLog.swift:7-20`):

- default capacity 256, configurable positive; when full, the oldest entry is dropped
  and a dropped counter increments;
- `ephemeralEvents(limit:)` returns a suffix (default 256), `droppedEphemeralCount()`
  returns the counter; neither is persisted;
- a durable batch MUST NOT contain an ephemeral event;
- an ephemeral event MUST NOT carry `commitSeq`; a durable event MUST carry one when
  stored;
- the ring is per open store instance and is empty after reopen.

## 7. Migration v1/v2 → v3

`migrateToV3()` runs during open for `user_version` 1 or 2
(`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:244-354`).

1. **Already split.** If `bot_events` is a view and `bot_event_headers` exists (a test or
   rollback fixture lowered `user_version`), the reference starts `BEGIN IMMEDIATE`,
   re-runs the idempotent DDL, sets `user_version=3`, and commits. It does not touch rows.
2. **Read old rows.** Old `bot_events(commit_seq, event_id, event_type, payload)` are read
   ordered by `commit_seq`; for `user_version >= 2`, `bot_user_action_nonces` is read too.
   A v1 database has no nonce table; its migrated set is empty.
3. **Drop and recreate.** With `foreign_keys=OFF`, one `BEGIN IMMEDIATE` transaction drops
   the old append-only triggers, drops `bot_user_action_nonces` and `bot_events`, runs the
   v3 DDL, and copies rows.
4. **Split each row.** The old `payload` is a full envelope. It is decoded with the
   stored-mode codec; `commit_seq`, `event_id` and `type` MUST match the row. The store
   computes `dataBytes = encodeData(event.data)`, writes
   `header_meta = encode(event with data {})`, `payload_digest = sha256(dataBytes)`,
   `payload_size = len(dataBytes)`, and inserts the header and payload rows.
   The new payload is the data object, not a substring of the old envelope; sizes can
   differ (for example the old full envelope for `{"text":"v2 payload first"}` becomes a
   27-byte payload whose digest is pinned by the vectors).
5. **Copy nonces.** Each old nonce row is copied unchanged; its `event_id` must still
   reference the migrated header.
6. **Contiguity before COMMIT.** Inside the migration transaction, before any DDL or
   copy is committed, the `commit_seq` values being migrated MUST be exactly
   `1, 2, 3, …` with no gap and no duplicate. The check applies to both migration paths:
   the old `bot_events` table and the already-split header table. A gap MUST abort the
   transaction. The error is the existing `corrupted`, whose detail names the first gap
   (`commit_seq gap: expected <n>, found <m>`); there is no second error code for this
   condition. Because the rollback precedes COMMIT, `user_version` stays at its old
   value and the old rows are untouched.
7. **Commit.** `PRAGMA user_version=3` and `COMMIT`; then `foreign_keys=ON` and
   `foreign_key_check`.
8. **On any error** the transaction rolls back, `foreign_keys` is restored, and the open
   fails as `corrupted` (or the underlying error). Reopening retries the same migration;
   the operation is idempotent.
9. **Order is observable.** The migration's contiguity check runs before the copy and
   before the version change. A v1/v2 file with a pre-existing gap is therefore refused
   by the migration and stays at v1/v2 after the failed open; the vector reads
   `PRAGMA user_version` after the refusal. A v3 file with a gap is refused later by the
   full integrity scan (§8) with `commitGap(expected:actual:)`. Both refuse the store;
   the migration condition is `corrupted` because no store state was ever opened.

New databases never run the migration: they create v3 directly and set `user_version=3`.

Rollback: a v1/v2-only App opening a v3 file MUST refuse it with `schemaTooNew` and MUST
NOT delete, downgrade or rewrite it (`spec/bot/v1/README.md` §1;
`Tests/PhoneDSHBotTests/Store/UserActionTransactionTests.swift:77-89`). There is no
downgrade migration.

## 8. Integrity and recovery

On open and on `verifyIntegrity()`, the reference scans every header/payload row
(`Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:528-618`):

- `quick_check` must be exactly `ok`; `foreign_key_check` must be empty;
- during a v1/v2 open, the migration itself first checks the old `commit_seq` set inside
  its transaction before COMMIT (§7 item 6). A gap there is `corrupted` naming the first
  gap, the transaction rolls back, `user_version` stays at the old value, and open fails;
- rows ordered by `commit_seq` MUST be `1, 2, 3, …` with no gap and no duplicate; a gap in
  the post-migration scan is `commitGap(expected:actual:)`;
- `header_meta` MUST decode as a durable event whose `commitSeq`, `eventId` and `type`
  equal the columns; otherwise `corrupted`;
- for a live payload: `erased_at` and `erasure_commit_seq` MUST be nil,
  `payload_size == payload.count`, and the SHA-256 of `payload` MUST equal
  `payload_digest`; otherwise `corrupted`;
- for a cleared payload: both markers MUST be present, `erasure_commit_seq > commit_seq`,
  and that sequence MUST name a committed `erasure` event; the envelope is validated with
  the sentinel data; otherwise `corrupted`;
- every nonce row MUST reference an existing event, `created_commit_seq` MUST equal that
  event's sequence, and the event's principal `botId` MUST equal the nonce `bot_id`;
  otherwise `corrupted`.

`bot_effects` and `bot_effect_inbox` are not part of the full scan beyond foreign keys;
their invariants are enforced by the transition code and the tests. A failure is
`corrupted` (or `commitGap`) and the store constructor throws; the caller MUST NOT use a
partially opened store.

Crash semantics: every mutation described here runs inside `BEGIN IMMEDIATE` and commits
with `synchronous=FULL` in WAL mode. A process crash before `COMMIT` leaves the old
state; a crash after `COMMIT` leaves the new state; there is no partial batch. The
`armCrashPoint`/`checkCrashPoint` hooks are *test-only Swift detail* and are not part of
the contract.

## 9. Effect outbox

The outbox is the host-wide at-least-once lane for external effects. It never claims
exactly-once. A handler MUST be idempotent when `idempotent: true`; a
non-idempotent effect MUST be executor-idempotent or explicitly reconciled.

### 9.1 States

`BotEffectState` strings stored in `bot_effects.state`
(`Sources/PhoneDSHBot/Journal/BotEffectOutbox.swift:5-14`):

`pending`, `leased`, `failed`, `acked`, `dead_letter`, `needs_reconciliation`,
`cancel_requested`, `canceled`.

Terminal states are `acked`, `dead_letter`, `canceled`. `cancel_requested` is not
terminal (it still holds a lease until `confirmCancel`). `needs_reconciliation` blocks
cancellation until resolved.

### 9.2 Enqueue

`enqueue` runs in one transaction (`BotEffectOutbox.swift:55-93`):

1. Validate: `effectKey`, `kind`, `operation`, `logicalKey`, `retryPolicy` non-empty;
   `generation >= 1`; `maxAttempts >= 1`; `notBefore >= 0` or nil.
2. If a row with the same `effectKey` exists with `generation >= incoming.generation`,
   return the key and write nothing (idempotent replay).
3. Otherwise append an `effect.enqueued` durable event (`eventId = evt:<uuid>`,
   `origin = local/effect-runner`, `principal.kind = ipc`) whose `data` includes
   `effectKey`, `kind`, `operation`, `target`, `payloadDigest`, `idempotent`,
   `retryPolicy`, `maxAttempts`, `generation`, `notBefore`.
4. Insert or replace the `bot_effects` row in `pending` with `attempt=0`, `attempts=0`,
   `enqueued_commit_seq` = the event's sequence, `not_before = notBefore ?? clock()`,
   and all lease/error/reconciliation fields NULL.

`maxAttempts` defaults when not supplied: `network-idempotent` 5,
`local-idempotent` 2, `local-nonidempotent` and `network-nonidempotent` 1; unknown policy
2 if idempotent else 1 (`Sources/PhoneDSHBot/BotEventLog.swift:28-56`). `target` defaults
to `canonicalResource`, `payloadDigest` to `argsDigest`, `retryPolicy` to
`local-idempotent`/`local-nonidempotent` from `idempotent`.

### 9.3 Lease selection and lease record

`lease(owner:now:)` uses the store's default TTL (30,000 ms by default;
`SQLiteDomainStore.swift:490-508`); `leaseNext(owner:now:ttlMs:)` takes an explicit
positive TTL. Owner non-empty, `now >= 0`, `ttl > 0`; otherwise `invalidConfiguration`.

Candidate rows, in this order (`BotEffectOutbox.swift:117-194`):

```
((state IN ('pending','failed') AND (not_before IS NULL OR not_before <= now))
 OR (state IN ('leased','cancel_requested') AND lease_expires_at <= now))
ORDER BY COALESCE(not_before, 0), enqueued_commit_seq, effect_key
```

The first candidate is handled as follows:

| Candidate state | Condition | Action |
| --- | --- | --- |
| `cancel_requested` (expired) | always | append `effect.reconciliation_required` reason `unknown-outcome`; set `needs_reconciliation`, clear lease |
| `leased` (expired) | `attempts >= maxAttempts` | same `unknown-outcome` reconciliation, no re-lease |
| `leased` (expired) | otherwise | re-lease: `attempt+1`, `generation+1`, write `effect.attempted`, state `leased` |
| `pending`/`failed` | `attempts >= maxAttempts` | append `effect.dead_lettered`, state `dead_letter`, clear lease |
| `pending`/`failed` | otherwise | lease: `attempt+1`, same `generation`, write `effect.attempted`, state `leased` |

Every successful lease sets `lease_owner`, `lease_expires_at = now + ttl`, `started_at =
now`, `not_before = NULL`, `reconciliation_reason = NULL`, and
`attempts = max(previous.attempts, attempt)`. It writes one `effect.attempted` event with
`effectKey`, `attempt`, `leaseOwner`, `leaseExpiresAt`, `startedAt`, `generation`.
`attempt` is the current lease number; `attempts` is the total number of leases ever
started and never decreases.

The candidate order above is the **only** selection order. A runner MUST call
`lease`/`leaseNext` and execute exactly the returned `effectKey`; it MUST NOT enumerate
`pending`/`failed` itself, sort them, filter candidates before the call, or reject the
store's choice because its own ordering named a different effect. The lease is not a
hint. A runner that cannot execute the leased kind follows the release or unknown-kind
rule in §9.5/§9.7; it MUST NOT substitute another effect.

### 9.4 Transition operations

All operations are one transaction with their durable events; the event append and the
row update commit or roll back together.

| Operation | Preconditions | Writes | Result |
| --- | --- | --- | --- |
| `renew(lease, now, ttl?)` | lease matches `generation`/`attempt`/`lease_owner` and state `leased`; `now >= 0`, `ttl > 0` | `effect.attempted` with same attempt/generation, new expiry | state stays `leased`, expiry `now + ttl`; `attempts` unchanged |
| `ack(lease, resultRef)` | if state `acked` with same generation/attempt → idempotent no-op; otherwise lease must match and state `leased` or `cancel_requested` | `effect.acked` (`resultRef` only when non-nil) | state `acked`, `result_ref`, `applied_at = now`, clears lease/`not_before`/`reconciliation_reason` |
| `ackReconciled(key, generation, attempt, resultRef)` | state `needs_reconciliation` and both numbers match | `effect.acked` with `reconciled:true` | same cleared state as ack |
| `fail(lease, errorClass, reason)` | `errorClass` in `transient|permanent|unknown`; lease must match and state `leased` or `cancel_requested` | `effect.failed`; plus `effect.dead_lettered` or `effect.reconciliation_required` when applicable | see §9.5 |
| `markNeedsReconciliation(key, reason)` | `reason` in `unknown-outcome|generation-conflict|receiver-mismatch`; already `needs_reconciliation` is a no-op; terminal is `invalidTransition` | `effect.reconciliation_required` | state `needs_reconciliation`, reason stored, lease cleared |
| `retryNeedsReconciliation(key, notBefore?)` | state exactly `needs_reconciliation` | a new `effect.enqueued` for `generation + 1` | row becomes `pending` with `attempt=0`, `attempts=0` |
| `requestCancel(key, reason)` | terminal or already `cancel_requested` → no-op; `needs_reconciliation` → `invalidTransition` | `effect.cancel_requested` when leased, else `effect.canceled` | `cancel_requested` keeps the lease; otherwise `canceled` |
| `confirmCancel(lease, reason)` | lease matches and state `cancel_requested` | `effect.canceled` | state `canceled`, `last_error = reason`, lease cleared |

A stale or forged lease (wrong generation, attempt or owner) is `staleLease`. An unknown
effect is `unknownEffect`. A terminal effect cannot be made to need reconciliation. A
second `markNeedsReconciliation` on an effect already in `needs_reconciliation` is a
no-op and writes no event; on a terminal effect it is `invalidTransition`.

### 9.5 Failure, retry delay and dead letter

`fail` computes (`BotEffectOutbox.swift:284-352`):

- `unknown`: append `effect.failed` + `effect.reconciliation_required` (reason
  `unknown-outcome`) as one durable batch; state `needs_reconciliation`;
  `reconciliation_reason = unknown-outcome`; clear lease and `not_before`. It never
  leases again until explicitly resolved.
- `permanent`, or `attempts >= maxAttempts`: append `effect.failed` +
  `effect.dead_lettered` as one batch; state `dead_letter`; clear lease/`not_before`.
- otherwise: append `effect.failed` with `nextAttemptAt`; state `failed`;
  `not_before = now + retryDelayMs`. The lease is cleared.

`retryDelayMs` is **0** for every policy except `network-idempotent`; for that policy it
is `min(1000 * 2^(attempt-1), 300000)` ms, with the exponent clamped to `0…8`
(`BotEffectOutbox.swift:610-614`). The delay is a store value, not a caller hint.
`unknown_effect_kind` is the frozen reason/`last_error` value for an effect whose kind is
outside the host catalogue (§9.7); it is not an `errorClass` value (`transient`,
`permanent`, `unknown` stay the only three).

### 9.5.1 Release of a known kind with no executor

A leased effect whose kind is **known** but whose executor is not registered MUST be
released, not failed and not dead-lettered. Release is a scheduling transition, not one
of the §9.4 effect transitions:

- `release(lease)` requires the lease to match `generation`, `attempt` and `lease_owner`
  and the row to be `leased`; otherwise it is `staleLease` or `invalidTransition`.
- In one transaction it sets state `pending`, `not_before = now + retryDelayMs` for the
  policy and the `attempt` that was leased, `last_error = "no registered executor"`, and
  clears `lease_owner`/`lease_expires_at`. It leaves `attempt`, `attempts`, `generation`
  and `started_at` unchanged; a released attempt still counts, so §9.3's max-attempt
  rule applies to the next selection.
- It writes no durable event: the lease's `effect.attempted` event is the record and no
  effect outcome occurred. It MUST NOT write `effect.dead_lettered`.
- The release is implemented by the store (`Sources/PhoneDSHBot/Store/SQLiteDomainStore+EffectRelease.swift:14-52`).
- The release exists for a known kind only. A kind outside the catalogue is
  `fail(permanent)` with reason `unknown_effect_kind` (§9.7), never a release.

`last_error` and every event `error`/`lastError` value are sanitized before storage:
the reference redacts `sk-[A-Za-z0-9_-]{8,}` and `Bearer <token>` and truncates to 500
characters (`BotEffectOutbox.swift:616-625`). A port MUST NOT store more.

`effects(state:)` returns rows ordered by `enqueued_commit_seq, effect_key`; no state
filter means all rows.

### 9.6 Inbox dedupe

`bot_effect_inbox` is the receiver-side idempotency table. `SQLiteBotEffectInbox.apply`
(`Journal/BotEffectInbox.swift:30-77`):

1. If an inbox entry for `(receiver, effectKey)` exists with
   `generation >= lease.generation`, return
   `{deduped:true, resultRef: stored.resultRef, entry: stored}` and do **not** execute.
2. Otherwise the lease must still match the effect (`generation`, `attempt`,
   `lease_owner`) and the state must be `leased` or `cancel_requested`; a forged/stale
   lease is `staleLease`, a wrong state is `invalidTransition`.
3. Execute the handler once, record `(receiver, effectKey, generation, attempt,
   applied_at, result_ref)` and return `{deduped:false, …}`.
4. Concurrent applies for the same `(receiver, effectKey, generation)` in one process
   coalesce onto one in-flight task and all but the first return `deduped:true` with the
   same result. This coalescing is *Swift detail*; the persistent dedupe is normative.
5. The dedupe check precedes the lease check, so a replay after the effect was acked (or
   after a restart) still returns the stored result instead of `invalidTransition`.

### 9.7 Executor contract

- Effects are delivered **at least once**, in the store's lease order. A runner MUST
  lease first and then execute exactly the `effectKey` it was leased; it MUST NOT keep a
  second `pending`/`failed` ordering, filter candidates before leasing, or reject the
  store's choice. The reference `BotProductionEffectRunner.runNext` leases first and
  dispatches on the leased row
  (`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeEffects.swift:106-131`).
- **Catalogue.** Effect kinds are a closed, host-declared set. The reference App declares
  exactly `routine-delivery` (`BotRoutineOutbox.kind`,
  `BotRuntimeEffects.swift:7`). The database column `bot_effects.kind` is `TEXT NOT NULL`
  and §9.2 only requires it to be non-empty, so a stored row can legally carry a kind the
  running host does not know; that is why the catalogue is explicit and separate from
  "a handler happens to be registered". A kind outside the host catalogue MUST be
  `fail(lease, errorClass:"permanent", reason:"unknown_effect_kind")`, which stores
  `last_error = "unknown_effect_kind"` and dead-letters the effect.
- A **known** kind whose executor is not registered MUST be released with `release(lease)`
  (§9.5.1): back to `pending` with the retry delay, never `fail(permanent)` and never
  `effect.dead_lettered`.
- A handler that throws MUST be mapped by the host to
  `fail(lease, errorClass:"unknown", reason:)` so the effect becomes
  `needs_reconciliation` with `unknown-outcome`; the outbox itself does not catch handler
  throws (`BotRuntimeEffects.swift:127-130`).
- The App's 250 ms poll interval is *Swift detail*, not a delivery guarantee or latency
  contract.
- Crashes, cancellations and timeouts do not prove an external side effect did not
  happen; the same effect key/generation is retried and reconciled, never re-keyed.

## 10. User-action transaction

This section freezes `Sources/PhoneDSHBot/Store/SQLiteDomainStore+UserAction.swift` and
the `BotUserAction`/`BotActionResult` shape in `Sources/PhoneDSHBot/Rows/BotUserAction.swift`.
The P27 planner decides *what* to commit; this section decides *how* it is committed and
which result the user sees.

### 10.1 Action shape and result codes

`BotUserAction` carries `nonce`, `botID`, `kind` (`chat|cardAnswer|cardDismiss|approval|
stopTask`) and the kind-specific optional fields `text`, `cardID`, `optionID`,
`approvalID`, `decision` (`allowOnce|always|deny`), `digest`, `threadID`, `attachments`
(`Rows/BotUserAction.swift:5-16`). The decoder rejects `customText`, a `cardAnswer` with
`text`, and attachments on a non-`chat` kind; those are decode failures, not result codes
(`BotUserAction.swift:98-121`).

`BotActionResult` is exactly one of (`BotUserAction.swift:123-171`):

| status | fields | meaning |
| --- | --- | --- |
| `accepted` | `eventID` | the action's event and effects committed |
| `duplicate` | `eventID` | the same `(botID, nonce)` was already committed; return the original event id |
| `stale` | `reason` | the action is well-formed but no longer applicable; nothing committed |
| `rejected` | `reason` | the action is invalid; nothing committed |

Freeze reasons produced by the action validation (`BotUserAction.swift:231-269`):
`invalid_action`, `unexpected_attachments`, `too_many_attachments`, `invalid_attachment`,
`missing_text`, `missing_card_id`, `unexpected_card_answer_field`, `missing_card_answer`,
`invalid_approval`, `missing_thread_id`, and the stale reason `digest_mismatch`.
Planner-originated stale/rejected reasons are owned by the P27 planner; they are passed
through unchanged and MUST NOT be rewritten here.

### 10.2 Validation before planning

`BotUserActionDispatcher.dispatch` (`BotUserAction.swift:174-229`) must:

1. check an in-process in-flight task for the same `(botID, nonce)` (Swift detail);
2. check `bot_user_action_nonces`; if present return `duplicate` with the stored event id;
3. run the validation table above and return `rejected`/`stale` without planning or
   writing;
4. call the planner with trust `owner_direct` (the only trust value);
5. `.stale`/`.rejected` pass through; `.commit(plan)` calls `performAndRecord`.

The planner/trust boundary is P27-owned. `BotUserActionDispatcher` is the only
owner-direct caller in the App; `performAndRecord` itself does not authenticate a caller,
so a port MUST keep the dispatcher inside the host module and MUST enforce that the
plan's event belongs to `action.botID`.

### 10.3 The commit transaction

`performAndRecord` runs entirely inside one `BEGIN IMMEDIATE`
(`Sources/PhoneDSHBot/Store/SQLiteDomainStore+UserAction.swift:11-60`):

1. **Nonce lookup.** `(bot_id, nonce)` is selected first. If present, verify that its
   `event_id` exists at `created_commit_seq` and return `duplicate(eventID:)`. A broken
   reference is `corrupted`. (The full principal-bot cross-check is part of the open
   integrity scan, §8, not of this hot path.)
2. **Action validation.** Run the validation table; `rejected`/`stale` returns without a
   write (and without consuming the nonce).
3. **Plan envelope.** Validate the plan event in append mode. The event MUST be durable
   and `event.principal.botId` MUST equal `action.botID`; otherwise `invalidTransition`.
4. **Event id conflict.** If `event_id` already exists in `bot_event_headers`, the
   transaction fails with `invalidTransition` (no nonce is consumed). This is not a
   duplicate: a duplicate is keyed by `(botID, nonce)`, not by event id.
5. **Effect keys.** Duplicate `effectKey` values inside the plan, or an `effectKey` that
   already exists in `bot_effects`, are `invalidTransition`.
6. **Commit the event.** Insert the action event at `head + 1`.
7. **Commit effects.** For each effect in plan order, append its `effect.enqueued` event
   at the next sequence and insert the `pending` row (`enqueueEffectInTransaction`,
   §9.2). Effects therefore occupy contiguous sequences after the action event.
8. **Commit the nonce.** Insert `(bot_id, nonce, event_id, created_commit_seq = action
   sequence)`.
9. The test-only crash hook runs before `COMMIT`; any throw rolls back all of 6–8.

The transaction is atomic across event, effects and nonce. A crash before `COMMIT` leaves
none of them; a crash after `COMMIT` leaves all of them and a retry returns `duplicate`.
Two connections racing on the same nonce serialize on the write lock: exactly one
`accepted`, the rest `duplicate` (`Tests/PhoneDSHBotTests/Store/UserActionTransactionTests.swift:217-249`).

### 10.4 Idempotency matrix

| Situation | Result | Writes |
| --- | --- | --- |
| first action for `(botID, nonce)` | `accepted(eventID)` | event + effects + nonce |
| replay of `(botID, nonce)`, any plan | `duplicate(originalEventID)` | none |
| same nonce, different bot | independent | independent |
| different nonce, same event id | `invalidTransition` | none; nonce not consumed |
| invalid action, unused nonce | `rejected(reason)` | none |
| approval without digest | `stale("digest_mismatch")` | none |
| plan event ephemeral or other bot | `invalidTransition` | none |
| duplicate/used effect key in plan | `invalidTransition` | none |
| crash before commit | error/rollback | none |
| crash after commit | error; replay is `duplicate` | all persisted |

A `duplicate` result MUST be returned even if the caller's retry carries a different
plan, event id or effects; the original committed event is the only authority.

## 11. Conformance and shared vectors

The shared vectors are phone-owned overlays under `spec/bot/v1/golden/`:

| File | Covers |
| --- | --- |
| `store.phone.json` | commitSeq assignment/dedupe/batch/ephemeral, canonical payloads and digests, v1/v2→v3 rows, gap/future-version refusal, outbox enqueue/lease/expiry/renew/retry/dead-letter/reconciliation/cancel/inbox |
| `user-action-transaction.phone.json` | accepted/duplicate/stale/rejected, event-id conflict, crash before/after commit, per-Bot nonce isolation |
| `event-envelope.phone.json` | the two `memory.document_*` durable types (valid and invalid envelopes) |

`python3 spec/bot/v1/tools/validate_vectors.py` validates the files and recomputes the
canonical payloads/digests and the state-machine expectations. Swift
`Tests/PhoneDSHBotTests/Store/BotStoreVectorTests.swift` and
`Tests/PhoneDSHBotTests/Store/BotUserActionTransactionVectorTests.swift` read the same
files from disk and run them through `SQLiteDomainStore` and the real codec. Kotlin
`:bot` must run the same files through its own store; a Python pass is not runtime
conformance.

## 12. Normative for any host vs Swift implementation detail

| Area | Normative for every host | Swift-only detail |
| --- | --- | --- |
| File root | the logical subtree `PhoneDSHBot/domain.sqlite` under the App-private support root; sidecars and private permissions | the exact `FileManager.applicationSupportDirectory` call and the Apple file-protection class |
| Open | WAL confirmed, `synchronous=FULL`, `foreign_keys=ON`, `secure_delete=ON`, 5,000 ms busy timeout, `user_version` policy, `quick_check`/`foreign_key_check` | `SQLITE_OPEN_FULLMUTEX`, actor/class names, `SQLiteDomainStoreError` spelling, SQLite error mapping |
| Schema | every table/column/constraint/trigger/view/index name and shape in §3; `user_version=3` | `CREATE TABLE IF NOT EXISTS` spelling, Swift string layout |
| Sequence and dedupe | dense `commitSeq`, store-assigned only, batch atomicity, duplicate/conflict outcomes, gap outcomes | crash-hook names and the test-only `armCrashPoint` |
| Bytes | canonical `data` bytes, SHA-256 over those bytes, `payload_size`, `header_meta` shape, erasure sentinel | Foundation `JSONEncoder` options and the `JSONValue` number representation |
| Migration | old row decode/check, split rows, nonce copy, one transaction, contiguity check before COMMIT, idempotence, post-failure open refusal | the exact SQLite statement layout and the Swift error spelling |
| Outbox | states, candidate order, lease/attempt/attempts, transitions, retry delay, release, dead-letter, reconciliation, inbox dedupe | the 250 ms App poll, in-process in-flight coalescing, handler registry and the App's explicit kind catalogue |
| User action | `(bot_id, nonce)` key, one transaction, result codes, frozen validation reasons, idempotency matrix | `BotUserActionDispatcher` in-flight map, planner implementation, `owner_direct` call site |
| Errors | the failure conditions and their observable codes/outcomes | the Swift enum case names; a port may map them to its own types |

## 13. Remaining and not frozen


- **Power-loss durability is not verified.** `synchronous=FULL` and the single-transaction
  rules are the profile; no repository test cuts power or corrupts a WAL. A kill/reopen
  test (the plan's `SqliteRecovery`) is not present in this repository.
- **Android SQLite configuration is not implemented.** `Context.filesDir`, WAL,
  `synchronous=FULL`, `foreign_keys`, `secure_delete`, the 5 s busy timeout and JSON1
  availability must be verified on the actual Android SQLite build; if a pragma cannot
  be honoured, report it rather than claiming Level 2 durability.
- **Erasure is not covered by a dedicated shared vector yet.** The DDL/triggers and the
  reference tests (`Tests/PhoneDSHBotTests/Store/BotEventStorageTests.swift:136-233`)
  exist; a port must still run its own erasure and `secure_delete` evidence.
- **The effect-kind catalogue is host-declared.** `bot_effects.kind` itself is
  `TEXT NOT NULL` and only checked non-empty (§3, §9.2); a port MUST declare its own
  closed catalogue and map a kind outside it to `fail(permanent)` with
  `unknown_effect_kind`. There is no database constraint to fall back on.
- **The App runner is outside the SwiftPM test target.** The store-side release and
  migration contract is tested in `Tests/PhoneDSHBotTests/Store`, but
  `BotProductionEffectRunner.runNext` itself is only compiled by the probe-app build; its
  runtime branch selection is not executed by `swift test`.
- `bot_effects`/`bot_effect_inbox` do not have a full integrity scan; a corrupt effect row
  is reported by the transition that reads it (`corrupted`), not at open.
