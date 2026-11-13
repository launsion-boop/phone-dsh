# Programmatic tool composition on the phone Worker — feasibility (W5, 2026-11-12)

- Scope: research only. Nothing in this report is enabled; `plugins/profile/phone.worker.cordis.patch.yml`
  keeps the top-level `ptc-runtime` / `workflow-ptc` / `tool-workflow` rows disabled.
- Base: `d988108c1` + contract freeze `e654fe99` (PC-20261112-w5-tool-catalog-roundtrips).
- Environment: Linux Fleet container; no WKWebView, no iOS simulator, no device. All runtime claims below
  are read from the pinned composition and the existing Worker-native implementation, not measured.

## 1. What is actually mounted today

The three `disabled: true` rows at profile lines 180–192 are **host rows**. They are not the whole story:

1. `ptc-runtime` would spawn a child Node process with a control fd (`plugins/README.md`, "Worker layer").
   WKWebView has no child-process API; the phone execution world rejects it.
2. The **standard** and **ptc** presets re-declare `workflow-ptc` + `tool-workflow` inside the preset
   (`plugins/profile/phone.worker.cordis.patch.yml` around line 699; `plugins/README.md` "Worker layer").
   The static-module table serves the official `@deepseek-ai/dsh-workflow-ptc` specifier from
   `@phone-dsh/dsh-workflow-worker`, so the preset gets the Worker-native engine without a DSH source patch.
3. `workflow-worker` keeps the official `meta`/`WorkflowExecution` semantics, runs the guest script in a
   QuickJS/WASM realm, starts child agents through `ctx.subagents.startActivation({ delivery: 'caller' })`,
   and revalidates provider, cwd, schema, Agent/session identity and budget before each child.
4. The **UI** does not project `tool/ptc-dispatch-start` / `tool/ptc-dispatch` today
   (`docs/receipts/ios-session-audit/01-data-path.md` DP-14, `06-tools.md`), so a PTC run would show a flat
   tool list with missing sub-calls. `run_code`-style nested execution is not visible.

So "turn on `ptc-runtime`" is not a switch that can be flipped in the profile: the row's substrate does not
exist on the phone, and the useful workflow path is already served by `workflow-worker`. What is missing is
the **programmatic tool-call transport** (`ptc-runtime` itself) and its UI projection.

## 2. What enabling would require

### 2.1 Runtime substrate

- A child-process-free PTC transport: the model's generated tool calls would have to be dispatched by a
  Worker-side interpreter (the QuickJS realm pattern already used by `workflow-worker`), with a control
  channel over the existing in-process `worker_threads`/`postMessage` bridge rather than a Node child fd.
- `ptc-runtime`'s contract surface (script → `tool.*` calls, results, cancellation) would need a Worker-native
  implementation that keeps the official meta/schema; the current `workflow-worker` only implements the
  `workflow` script dialect (`agent`/`parallel`/`pipeline`/`phase`/`log`/`args`), not arbitrary tool calls.
- A hard, non-configurable call-depth and fan-out cap (the official UI uses `MAX_DEPTH=256`; the phone needs a
  much smaller product limit), a per-turn token/tool budget, and a synchronous-loop interrupt (already present).

### 2.2 Child agents and permissions

- `ctx.subagents.startActivation` already exists and is used by `workflow-worker`. PTC would need the same
  parent-side revalidation for every nested call: provider, model, cwd, schema, Agent identity, Task
  authorization subset (`task.write-dir:*`, `task.network-write`, `task.delegate`), and the Bot workspace root.
- Nested calls must not bypass the `approval-gate`: each side-effecting call still needs exactly one identity
  registration and one approval decision (W5 §2.2). A PTC loop cannot batch approvals into one card.
- Egress writes from nested `bash` must attribute to the enclosing Bot session/job; the existing background-job
  registration TTL and `bot_egress_ambiguous` rules apply unchanged.
- The QuickJS realm is an in-process software realm, **not** an OS or hardware privilege boundary. A future PTC
  interpreter must not be described as a sandbox.

### 2.3 Tool catalog

- `tool-workflow` (and any future `run_code`/PTC tool) is a Bot tool. W5 tiering puts it in the core tier only
  once it is actually callable; a device-only or discoverable-only row would make the model "find" a tool that
  cannot run. The catalog change must go through `spec/bot/v1/tool-catalog.schema.json` as an additive tier
  entry, not a local enum.
- Tool-list churn restarts the upstream request sequence and costs prompt cache. Enable it per profile/preset
  and keep the list stable for the whole session.

### 2.4 UI and UX

- The chat projector must map `tool/ptc-dispatch-start` / `tool/ptc-dispatch` into nested child rows
  (`rootCallId`, `callId`, `name`, `status`) with a bounded depth and a clear collapsed state. Without it the
  user sees a parent call and no children, which is worse than not offering PTC.
- No new user-facing banner or "PTC unavailable" notice is allowed by the experience rules. If the capability
  is off, the tool simply is not in the catalog.

### 2.5 Composition

- Pick a preset that already declares `workflow-ptc` + `tool-workflow` (standard/ptc), not the legacy `phone`
  preset. Add the Worker-native PTC transport only when 2.1 exists.
- The packer's static-module table, not a DSH source patch, must keep serving the official specifier.
  `scripts/ci/no_dsh_patch.py` must stay green.

## 3. Risks

| Risk | Why it matters on a phone | Mitigation to design before enabling |
|---|---|---|
| Unbounded nesting / fan-out | model-generated loops can multiply tool calls and tokens | hard depth, fan-out and per-turn budget; parent watchdog |
| Approval batching | a loop could hide many side effects behind one card | one registration + one decision per side-effecting call |
| Cancellation | a wedged guest must not keep child agents alive | QuickJS interrupt + parent isolate termination (exists) + child disposal |
| Cost | PTC's point is fewer round-trips, but scripts can be larger than the calls they replace | measure input/output tokens against the W0 fixture; no claim without data |
| UI invisibility | missing `tool/ptc-dispatch*` projection hides what ran | projector + nested-row tests before enabling |
| Security boundary confusion | QuickJS is not an OS sandbox | document and test the in-process boundary; keep approval/egress gates authoritative |
| Prompt-cache churn | a changing catalog restarts the upstream sequence | stable per-session catalog; enable per preset, not per request |

## 4. How to verify before enabling

All of these are required; none is satisfied by the static spec checkers.

1. **Node unit tests** (Linux, real Worker packages):
   `cd plugins && npm ci && node scripts/run-tests.mjs "tests/workflow-worker.test.ts" "tests/bot-tool-surface.test.ts"`.
   Add a PTC dialect test only after the transport exists; it must run a real script through the real bridge.
2. **Packed-image test**: build the Worker image and run the standard preset through a scripted model that
   emits a PTC script; assert the tool catalog, child calls, approval count and terminal events.
3. **Mac simulator**: WKWebView + the packed image; verify the projector renders nested child rows and that
   cancellation/terminal states are visible. This is `NOT_RUN` on Linux.
4. **Real device**: 56-scenario G2 batch ≥ baseline, 8-hour heavy run (plan §1.3), kill matrix for a killed
   child/Worker, and token/round-trip measurement against the W0 fixtures.
5. **Security**: nested bash/write outside the Bot root still gets one approval; egress writes are attributed;
   a guest `while (true)` is interrupted; no `fetch`/`import`/filesystem escape from the realm.
6. **Rollback**: remove the PTC tool from the profile/preset and verify old sessions resume with a flat tool
   list, no persisted PTC state, and no replay of side effects.

## 5. Recommendation

Do **not** enable PTC in this round. The Worker-native `workflow-ptc` engine is already mounted by the
standard/ptc presets and can be measured independently; the missing pieces are the PTC tool-call transport,
its permission/cancellation wiring, and the nested-tool UI. Track those as a separate work package with the
verification list above. Flipping the three top-level `disabled` rows would not provide PTC and would risk
starting a runtime the Worker cannot host.
