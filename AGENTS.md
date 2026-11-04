# Agent collaboration

Applies to the whole repository (Swift, TypeScript, Kotlin, Rust). `CLAUDE.md`
imports this file through `@AGENTS.md`. A nearer `AGENTS.md` in a subdirectory adds rules for that subtree;
the user's explicit instructions in the conversation take precedence over both.

The one thing this file exists to prevent: **two agents changing the two ends of a
boundary in two different ways.** phoneDSH is one protocol implemented four times.
Every rule below serves that goal.

## 1. Before you edit: is this a protocol change?

Open the [protocol baseline](spec/README.md) and match your planned diff against
its **path → contract trigger table (§4)**. Quick guide:

| If your diff touches… | You are touching |
| --- | --- |
| `spec/**` (any schema, golden, normative doc) | the contract itself (§3 owner) |
| `Sources/PhoneDSHWire`, `plugins/channel`, `shell/crates/pdsh-wire`, `android/**/wire`, HELLO code | P01 channel |
| WAL, `PhoneDSHLog`, `pdsh-wal`, `android/core/**/log` | P02 persistence |
| controller, handoff, journal, exec-bridge, ledger | P03 / P17 |
| `WebEngine*.swift`, `postMessage`, `webkit.messageHandlers`, WebView engine | P04 bridge |
| gateway, loopback HTTP, llm-bridge, `android/net` | P05 |
| `AgentHarness`, `DSH/`, host events, `android/**/agentcore` | P06 |
| `/api/remote.mux`, `/api/pdsh-*`, Worker URL params / `PDSH_*` env / `__PDSH_*` globals | P14 / P15 / P16 |
| `shell/include`, FFI, JNI, `Package.swift` | P12 native ABI |
| a plugin `contract*.ts`, `protocol.ts`, `remote.ts`, `types.ts` | P10 / P11 / P13 |
| a file another module, language, process or **older on-disk data** reads | a protocol — register it if it is not listed |

- **Yes** → follow §3 below. Write `Protocol impact: P0x …` in the task/PR.
- **No** (private refactor, identical observable behaviour) → name every triggered
  ID with its own reason, e.g. `Protocol impact: P01; P09: none — UI comments only`.
  Bare IDs declare impact; `P09: none — reason` justifies no impact for P09 only.
  A global `Protocol impact: none — <reason>` is accepted only when no ID triggers.
  Do not count an ID mentioned inside a reason as a declaration.
- **Unsure** → treat it as yes. A wrong "none" is the failure this file prevents.

## 2. Non-negotiable rules

Each rule exists because breaking it has already happened or is cheap to repeat.

1. **One authority per boundary.** The owning contract in the baseline registry
   decides. Change it there first, together with its schema and golden. Never
   copy a schema into code, add a second envelope, alias a field, or add a second
   error code for an existing meaning (GAP-05 is what that looks like).
2. **Never fix one end alone.** If the boundary has a producer and a consumer,
   your change either updates both, or the delta records why one end is
   intentionally left and how old/new versions interoperate.
3. **Never loosen the contract to make your platform pass.** Do not widen a schema,
   drop a validation, delete a fixture, grow an allowlist, or mark a check skipped
   to get green. If the spec looks wrong, stop and raise a contract change (§3.3).
4. **`target`, `draft`, `[NEW]` and reserved items are not features.** Do not call
   them, and do not migrate a caller to a target format without its receiver,
   compatibility decision and runtime evidence on both ends.
5. **Compatibility is per boundary.** Apply the general rules in baseline §5.1 and
   the owning boundary's own version / unknown-field policy. Do not import
   protobuf, JSON-RPC or host-event rules into a boundary that does not use them.
6. **Preserve semantics, not just shapes.** Correlation IDs, sequence domains,
   cancellation, deadlines, idempotency, backpressure, durability and security
   checks are part of the contract (baseline §6). Acceptance ≠ durable ≠ executed.
7. **Do not invent protocol surface for convenience.** No new wire field, frame
   type, capability, version field, env var or dependency just to suit a coding
   style. Each needs a delta and a compatibility answer.

## 3. How agents collaborate on a protocol change

Three roles. One agent may hold several of them in a small task, but it must
still produce each role's output. The coordinator holds contract owner unless the
task names someone else. These are review duties, not extra human approvals.

### 3.1 Coordinator / contract owner — freeze the contract first

Before any dependent implementation starts, the coordinator publishes a
**contract freeze** in the task or PR, using
[the change template](docs/protocol-change-template.md):

- base commit SHA, contract IDs, and the concrete trigger → current → expected;
- the delta: fields, encoding, limits, errors, cancel/retry, compatibility matrix
  (old→new, new→old, new→new, old data→new/rollback) and version decision;
- the edited owning spec/schema/golden (or code-contract file), committed at a
  stated **contract revision**, with shared valid **and** invalid fixtures;
- file ownership per implementer (disjoint paths or worktrees) and the exact
  acceptance commands per end.

Only the contract owner edits files under `spec/` and the code-contract files
listed in baseline §3 during the task.

### 3.2 Implementers — build against the frozen revision

- Work only inside your assigned paths. Do not edit `spec/`, another end's
  implementation, or another agent's files.
- Implement against the stated contract revision and its shared fixtures. Your
  tests must drive the **real** encoder/decoder or state machine with those
  fixtures, not a hand-written copy.
- Producer and consumer may proceed in parallel once the freeze exists.

### 3.3 When the contract is wrong or incomplete — stop, do not patch

An implementer who finds the frozen contract ambiguous, wrong, or impossible on
its platform **does not work around it**. It stops that part and reports:

```
CONTRACT CHANGE REQUEST
Contract: P0x @ <revision>   Clause: <file#section>
Problem: <what cannot be implemented as written, with evidence>
Proposal: <smallest delta>   Affects: <other ends>
```

The contract owner updates the change record and the owning contract, issues a
new revision, and tells every affected end. Nobody adds a local field, alias,
fallback, or platform-only branch in the meantime.

### 3.4 Reviewer / integrator — prove both ends agree

- Review the combined diff at one head SHA, not each part in isolation.
- Confirm every end listed in the delta changed, or has a recorded reason.
- Confirm the shared fixtures run through each end's real decoder, including the
  invalid and failure/reconnect cases that changed. A spec checker passing is
  not runtime conformance.
- Resolve disagreements in the owning contract and its fixtures, then re-run
  every affected end. Record any newly found divergence as a GAP in the baseline.

### 3.5 Handoff evidence (every role, every task)

```
Base / head:        <sha> / <sha>
Protocol impact:    P01; P09: none — <P09-specific reason> | global none only if no IDs trigger
Contract revision:  <sha or file@rev>
Changed files:      <by end>
Status per end:     implemented | partial | not started
Commands → result:  <exact command> → PASS | FAIL | SKIP | INCOMPLETE | NOT_RUN
Not verified:       <device, power-loss, model E2E, other platforms…>
Remaining risks:    <and the GAP/owner that tracks them>
```

Report results exactly as observed. Do not upgrade `SKIP`, `NOT_RUN` or a
simulator run into a device claim.

Do not start additional agents unless the user's task or applicable instructions
authorize delegation. These rules describe how to coordinate authorized work.

## 4. Read before changing code

1. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the
   [protocol baseline](spec/README.md) (§3 registry, §4 triggers, §7 known gaps).
2. Record the working tree, branch, HEAD and task scope. Preserve unrelated work;
   an old checkout, a proposal or another agent's candidate is not the baseline.
3. For the affected contract, read the owning source, **both** ends, and their
   tests before proposing a new abstraction.
4. A known gap in baseline §7 is maintenance debt, not permission. Do not build
   on the looser side of a gap; fixing one follows §3 like any other change.

## 5. Verification

- Use the baseline's verification matrix (§8). `bash scripts/ci/check.sh --list`
  is the command inventory. Run what the actual diff affects.
- Contract edits: `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
- P01/P02 codec edits also need `bash scripts/ci/check.sh --only phone-rust-tests`
  (runs `cd shell && cargo test -p pdsh-wire -p pdsh-wal`). Missing cargo is SKIP /
  INCOMPLETE, never PASS. Record the actual result explicitly.
- Behaviour changes need a regression on the real owning boundary, reusing the
  shared golden vectors, including invalid input and the changed failure path.
  Keep checker mutation tests effective.

## 6. Repository boundaries

- No DSH source patching or vendoring. Preserve the narrowly documented pack-time
  exception in CONTRIBUTING; upstream needs go under `docs/upstream/`.
- Preserve Package.swift/Android module boundaries and the shared Worker source.
  Use `spec/platform` for justified OS differences. Rebuild affected Worker assets
  before claiming an app runs new plugin code.
- Add a new generator, gate, hook, protocol layer or dependency only for a
  concrete gap existing tools cannot cover; baseline §9 lists the planned ones.
- Do not infer device, power-loss, model E2E or deployment success from static
  checks, unit tests or a simulator. Report only what was actually run.
