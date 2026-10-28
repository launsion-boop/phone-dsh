# G2 scenario catalog and runner

Catalog-driven, real-model scenario runs on the phone DSH stack (PLAN §8).
Each scenario is a clean workspace, one or more ordinary user prompts, an
optional perturbation (planned restart, background park/resume, Worker kill,
WebContent kill) and mechanical assertions against the materialized workspace.
The model is the real DeepSeek provider the user's local `dsh` uses by default;
the API key is injected by the Swift host model gateway and never reaches the
Worker.

- `catalog.json` — the designed batch (ids `G2-<part><nn>`, 10 fixtures; part E is office work: documents, spreadsheets, slides).
- `selftest.json` — the runner gate (`G2-SELFTEST`, `G2-SELFTEST-DELIVERY`) and
  the delivery fail-loud self-tests (`G2-SELFTEST-DELIVERY-STALL`,
  `G2-SELFTEST-DELIVERY-128K`), mock upstream. `G2-SELFTEST` also carries the
  two-phase `workspace_command` assertion. `G2-SELFTEST-REPORT-SCHEMA` is an
  expected-timeout fixture (the smallest wall budget plus a stalled mock reply)
  consumed by the Swift report-schema regression, not by the batch report gate:
  it intentionally ends `TIMEOUT`, so `scenarios.sh --only` is not its gate.
- `fixtures/<name>/files/` — deterministic fixture payloads.
- `fixtures/<name>/fixture.json` — optional deterministic git history.

## Catalog inventory and budget

The checked-in catalog is **56 scenarios** (`A10 B10 C10 D6 E10 F10`) over
**10 fixtures**. The stale 36/46 counts from earlier drafts do not describe this
tree; the machine-readable inventory and lane plan live in
`catalog.json` `run_plan` (`run_plan.inventory`, `run_plan.budget`,
`run_plan.lane_plan`) and are validated by `scenario_batch.py`.

- 50 normal scenarios: 500 max-minutes and 1220 max model requests.
- 6 `long-run` D scenarios: 335 max-minutes and 1320 max model requests.
- Serial catalog ceilings: **835 max-minutes** and **2540 max model requests**.
  `G2-D06` is the largest single scenario (75 min / 260 requests).
- Two macOS lanes: `lane-1` has 28 scenarios (405 min / 1235 requests hard
  ceiling), `lane-2` has 28 (430 min / 1305 requests, ending at `G2-D06`).
  These are budget ceilings, not measured wall time; actual wall time depends
  on how much of each scenario budget is used.
- The simulator pass is the 9-scenario subset (6 long-run + `C06`–`C08` +
  `A09`/`A10`): 385 serial max-minutes.

## How to run

Run the commands below from the repository root. Relative `--catalog` paths are
resolved against the repository root; a relative `--results` path is resolved
against the directory the command is invoked from (the batch orchestrator uses
an absolute directory per lane).

Mock upstream (no key, used by CI and the self-test):

```sh
bash scripts/ci/scenarios.sh --upstream mock --only G2-SELFTEST
```

Real model (the user's local DSH credentials):

```sh
eval "$(node scripts/ci/model-env.mjs)"
bash scripts/ci/scenarios.sh --upstream real
```

iOS Simulator (the same catalog, engine and evidence; this is the runner to use
when the Mac console is locked, because a macOS WKWebView page is hidden by
occlusion while the simulator page stays visible):

```sh
# Mock upstream selftest (the CI gate):
bash scripts/ci/scenarios.sh --run-on sim --upstream mock \
  --only G2-SELFTEST,G2-SELFTEST-DELIVERY

# Real model: credentials travel only in the xcodebuild test-runner env.
eval "$(node scripts/ci/model-env.mjs)"
bash scripts/ci/scenarios.sh --run-on sim --upstream real

# A real iPhone (NOT_VERIFIED in this tree; see the probe runbook):
bash scripts/ci/scenarios.sh --run-on sim --upstream real \
  --destination 'platform=iOS,id=<device-udid>'
```

`--run-on macos` is the default; its execution segment is byte-for-byte the
`swift test --filter PhoneDSHScenario` command and environment. `--run-on sim`
builds and installs the probe app, stages the inputs in its container, runs
`PhoneDSHScenarioSimTests` through `xcodebuild test`, and pulls the per-scenario
evidence into `--results`. The engine itself is the regular SwiftPM library
`Sources/PhoneDSHScenario`; both suites are XCTest glue.

One shared build-stage difference is deliberate and explicit: the build cache is
produced by invoking `smoke.sh` once (that script owns the build steps and then
runs the macOS smoke as its own gate). If that invocation's smoke test fails but
its build products (`worker-entry.js`, the staged `tool-worker-python.js`/
`tool-worker.js`, `boot.js`, `index.html` and `image.tar.gz`) exist,
`scenarios.sh` prints a warning naming `build.log` and reuses the products
instead of failing the batch. The products are complete before `smoke.sh`
starts its test, `--run-on sim` needs this on a locked Mac console (the hidden
macOS page makes the smoke test fail), and the macOS smoke remains independently
guarded by the `smoke` and `sim` gates. The selected runner's per-scenario
evidence is this script's gate.

Staged layout inside the probe app container:

```text
Documents/pdsh-scenarios/
  catalog.json     # the selected catalog, unchanged
  fixtures/        # scripts/ci/scenarios/fixtures/ (git history prebuilt
                   # host-side; the staged fixture.json omits the git block)
  config.json      # upstream, only, tag, target, keep_bodies — no credentials
  results/<id>/    # report.json, transcript.jsonl, workspace.tar, host/ ...
```

The model key is passed as `TEST_RUNNER_PDSH_MODEL_BASE_URL/NAME/API_KEY` to
`xcodebuild` and read from the test-runner environment; it is never written to
`config.json`, the results, or a log, and the runner's redactor still removes
authorization material from every artifact. `PDSH_SCENARIO_SIM_DIR` overrides the
simulator build/staging directory (default `$TMPDIR/pdsh-scenarios-sim`);
`PDSH_SIM_DEVICE` selects the simulator when `--destination` is omitted.

`eval "$(node …)"` prints and exports exactly three variables; the script never
echoes them, and the runner redacts authorization material from every artifact.
Set `DSH_HOME` to the harness home that owns `.credentials.yaml` if it is not
`~/.dsh`.

Flags (the batch orchestrator calls these exact names):

| flag | default | meaning |
|---|---|---|
| `--catalog <path>` | `scripts/ci/scenarios/catalog.json` | catalog document |
| `--results <dir>` | `$TMPDIR/pdsh-scenarios` | per-scenario artifact root |
| `--only id1,id2` | all | comma-separated scenario ids |
| `--tag <tag>` | all | keep scenarios carrying the tag |
| `--target macos\|sim\|both` | `macos` (macOS run), `both` (sim run) | catalog target filter, **not** an execution target |
| `--run-on macos\|sim` | `macos` | execute with `swift test` or in the iOS Simulator probe project |
| `--destination '<xcodebuild destination>'` | simulator named by `PDSH_SIM_DEVICE` | `xcodebuild -destination` for the simulator/device run |
| `--upstream real\|mock` | `mock` | scripted mock or real DeepSeek |

Parallelism is one WKWebView per test process: `scenarios.sh` runs a single
`swift test --filter PhoneDSHScenario` process, so the batch orchestrator may
start several lane processes (each with its own results directory). The run
maps the selection onto a fixed bank of 64 static slot test cases (SwiftPM's
`--filter` ignores a dynamic suite); unused slots skip, and each selected
scenario still runs in its own XCTest case. A selection larger than the bank is
rejected before any scenario runs (the selection guard fails and every slot
skips), so a batch never partially executes. A scenario
test may seed, boot and stop several WKWebViews over its lifetime, but never two
at once. For direct `scenarios.sh` runs, the build cache lives in
`$TMPDIR/pdsh-scenarios-build`; the first lane builds it through `scripts/ci/smoke.sh` (the build steps live only in that
script) and later lanes reuse it. `smoke.sh` stages both tool workers
(`tool-worker-python.js` and `tool-worker.js`, plus their source maps) beside
`worker-entry.js`; the batch precheck requires exactly those staged bytes.

## Batch orchestration and receipts (`scenario_batch.py`)

`scripts/ci/scenario_batch.py` is the thin execution layer around
`scenarios.sh`. It is Python-stdlib only, does not replace the runner, and does
not duplicate the credential resolver:

Unlike a direct `scenarios.sh` invocation, batch `run`/`resume` require verified
assets before launching a lane. Prepare them with `scripts/ci/smoke.sh` (or a
direct scenario run) first, then supply the resulting `PDSH_DSH_WWW` and
`PDSH_DSH_IMAGE`, or use an already complete default build cache. A cold missing
cache is an explicit execution error; `plan` does not build assets.

```sh
# Read-only: validate that the lane plan is an exact partition of the catalog.
python3 scripts/ci/scenario_batch.py plan --batch-dir /tmp/pdsh-g2-batch \
  --out /tmp/pdsh-g2-plan.json

# Real-model batch: export the existing model environment first.
eval "$(node scripts/ci/model-env.mjs)"
python3 scripts/ci/scenario_batch.py run --upstream real --run-on macos \
  --batch-dir /tmp/pdsh-g2-batch

# Explicit resume: only a PASS with the same identity + complete evidence is reused.
python3 scripts/ci/scenario_batch.py resume --upstream real --run-on macos \
  --batch-dir /tmp/pdsh-g2-batch

python3 scripts/ci/scenario_batch.py summary --batch-dir /tmp/pdsh-g2-batch
```

`plan` reads `run_plan.lane_plan` (or deterministically balances the catalog when
a test catalog has no metadata) and fails unless every catalog id appears
exactly once. Each lane gets its own `results/`, `sim/` and `work/` directory
under the batch directory. `--lanes N` is an explicit deterministic override;
the simulator path needs one distinct simulator per lane via
`--simulators 'iPhone 17 Pro,iPhone 17 Pro 2'` (a single simulator is one lane).
Pass the same `--lanes`/`--simulators` values to `resume`; the simulator names
are part of both the lane layout and the engine fingerprint, so a changed
device assignment is never reused.

`run` starts one lane process at a time within a lane and lets lanes overlap.
Because the Swift selector preserves catalog order, a lane whose desired order
is not catalog-increasing is split into contiguous `scenarios.sh` invocations
(D scenarios after the normal E/F block in the lane plan), all writing the same
lane `results/`. Output is streamed through the credential redactor to
`work/scenarios.log`; a real run's `PDSH_MODEL_*` values are inherited by the
child and are never copied into `batch.json`, receipts, summaries or logs. The
redactor retains a bounded suffix between reads and streams newline-free output,
so a key that is neither `sk-`-shaped nor labelled is still removed when a pipe
read cuts it in half. The generic `sk-` rule includes the `._-` characters used
by provider key shapes such as `sk-proj-...` and `sk-ant-api03-...`, and holds
an incomplete trailing token until its terminator (or EOF) so a chunk cut cannot
leave its suffix behind. An unfinished `(Proxy-)Authorization` header line is
held raw until its newline (or EOF) as well: the generic rule replaces the
scheme together with the value, so redacting the first chunk while the cut is
inside `Basic`/`Bearer` (or just before the value) would let the next chunk's
token arrive without a label. A pathological newline-free header is sealed
after the bounded hold and dropped through its terminator instead of growing the
pending buffer.

`scenarios.sh` has no fixture-root flag: it computes `$ROOT` as `$HERE/../..`
from its own location and always seeds
`$ROOT/scripts/ci/scenarios/fixtures`. `scenario_batch.py` derives that exact
root from the resolved `--scenarios-script`, not from `--repo-root` and not from
`<script-dir>/scenarios/fixtures`; a copy at a non-canonical path such as
`<root>/tools/runner/scenarios.sh` records the fixtures that child actually reads
under `<root>/scripts/ci/scenarios/fixtures`.

`run` and `resume` also require the resolved runner's source checkout
(`$HERE/../..`, where `scenarios.sh` changes directory before `swift test` or
`xcodebuild`) to equal `--repo-root`. A script in another checkout is therefore
a **plan-only** view: `plan` may show it and hash that checkout's fixtures, but
it reports `execution_ready = false`, and `run`/`resume` refuse it before
starting any child instead of receipting one checkout's source/pin while the
child builds another. A non-default `scenario_batch.py --fixtures-root` is
plan-only for the same reason. The default root is recorded as
`fixture_root_source = "runner-default"` in the manifest and every receipt, and
`summary` recomputes it from the manifest's resolved script. A wrapper that
`exec`s a *different* `scenarios.sh` cannot be inferred from the wrapper path;
pass that target script directly instead.

The engine identity is the bytes the real child will consume, not a path guess:
before the first lane starts, `run`/`resume` resolve the same
`PDSH_SCENARIO_BUILD_DIR`/`PDSH_DSH_WWW`/`PDSH_DSH_IMAGE`/`PDSH_PYTHON_ARTIFACTS`/
`PDSH_JQ_ARTIFACTS` paths that `scenarios.sh` uses, then require and hash the
Worker bundle tree (all regular files and symlink targets; empty directories
such as the runner-created `lazy/` are ignored), the image and
`plugins/dsh-pin.json`. The bundle must contain non-empty `worker-entry.js`,
`tool-worker-python.js`, `tool-worker.js`, `index.html`, `boot.js` and
`phone-dsh-provenance.json`. When `PDSH_DSH_WWW` and `PDSH_DSH_IMAGE` are both
supplied, `scenarios.sh` takes its prebuilt branch and never reads the external
Python/JQ directories: the identity records `mode=prebuilt` and marks those
pairs `consumed=false` instead of receipting bytes the child did not use. With
no prebuilt pair, `scenarios.sh` uses the default build cache, whose freshness
check and rebuild read the Python `python.wasm`/`python313.zip` and jq
`jq.wasm`/`engine.json` pairs; those pairs are required and hashed there. A
missing/empty required asset, a cross-checkout runner, or a missing pin is a
fail-closed execution error. Changing any consumed asset changes the engine
fingerprint, so `resume` reruns the batches rather than reusing a PASS, and
`summary` re-reads the recorded paths and blocks if their bytes changed. After
every lane exits, and before writing any receipt, the batch recomputes the
source, catalog, fixture and engine identity. If a child rewrote a tracked
source file, the catalog, a fixture, or a stale default build cache, every
receipt for that invocation is `BLOCKED` rather than a PASS for pre-run bytes;
restoring the old bytes later does not make those blocked receipts reusable, so
`resume` actually reruns the scenarios.

The model identity stores the upstream name, the endpoint host, a SHA-256 of the
sanitized base URL and a non-secret credential-context id. It never stores the
API key or a key digest. Before hashing, the batch removes userinfo and
credential-shaped query values, and replaces known API-key values in the
hostname, the path and in every retained query value, including raw,
case-varied and percent-encoded forms. The complete raw URL is sanitized before
`urlsplit` runs, so a key containing `/` or `?` cannot escape userinfo into the
host/path/query and be hashed as part of the original URL; if a known key still
survives in the sanitized endpoint, the identity fails closed to
`<invalid-url>` instead of writing or hashing it. A non-credential query name
such as `?code=<PDSH_MODEL_API_KEY>` therefore cannot turn the endpoint digest
into an offline-guessable credential digest, and a key embedded in the host
cannot be written to `batch.json` as plaintext.
Because a key cannot reveal whether a rotated key still addresses the same
tenant/deployment, `PDSH_MODEL_CONFIG_ID` may pin that non-secret context (for
example `tenant-a/deploy-1`). A real run still works without it; the identity
then records `credential_context.source = "unknown"`, `summary` warns, and an
explicit `resume` reruns real scenarios instead of reusing a prior PASS.
With the same explicit id, rotating only the API key keeps the identity stable
and a complete prior PASS may be reused.

Each scenario gets a receipt under `<lane>/work/receipts/<id>.json` with the
source SHA, catalog SHA-256, fixture root provenance and hashes, credential
context, model/engine fingerprints, report status, attempt and the SHA-256 of
every required evidence file/tree. `resume`
first requires the previous `state.json` to be `finished`, with every executed
lane at returncode 0 and no timeout; a missing state, a failed lane or a state
that never completed disables reuse and reruns the work. When that state is
valid, a prior `PASS` is reused only when all of those identity fields match,
the report's `id` and `attempt` still match the capability index, and the
complete evidence hash map is byte-identical. `FAIL`, `TIMEOUT`, `BUDGET`,
`ERROR`, `SKIP`, `INFRA`, `PENDING_HOST`, a missing report, a stale report from
an interrupted run, a changed catalog/source/model/engine or simulator, an
unknown real credential context, a plan-only fixture root, or a changed
evidence file are never reused as a pass; they are executed again (or stay
non-PASS in the summary).

`summary` writes `summary.json`/`summary.md` and exits 0 only when every
catalog scenario is `PASS`. The only aggregate states are `PASS`, `FAIL`,
`NOT_RUN`, `BLOCKED` and `PENDING_HOST`; a missing, interrupted or structurally
incomplete `state.json`, a runner failure, a missing report, a report/attempt/
source-id mismatch, a missing receipt or an identity/evidence mismatch makes the
batch non-zero. Without a finished state, reports and receipts are never trusted
on their own. `--expect-source-sha` and `--expect-catalog-sha` pin the receipt
to an operator-supplied identity. The tool has no daemon, database or external
account configuration.

## Model environment (`model-env.mjs`)

`model-env.mjs` resolves the same default provider as the user's `dsh` through
the pinned checkout's own modules:

- `$DSH_HOME/.credentials.yaml` (`$DSH_HOME` defaults to `~/.dsh`) is parsed
  with `resolveSpec` + `parseCredentialsDocument` from
  `packages/credentials/credentials-local` (the document `LocalCredentialProvider`
  serves at runtime; the script does not boot a Cordis context, so it reproduces
  the same managed-`refs`-first precedence and 0600 permission rule). The
  document layout is the version-1 `refs:` map, and the key is
  `refs.<apiKeyEnv>` where `apiKeyEnv` is the composed `llm-deepseek` row's
  value (default `DEEPSEEK_API_KEY`).
- The default model row is composed without booting by `packages/boot/app-boot`
  (`loadOptionalPatches` + `composeEntries`) from the checkout's selected
  bundles, the profile's `cordis.patch.yml` and the harness-home patch. The
  profile is `$DSH_PROFILE` when set, otherwise the only profile directory in
  `$DSH_HOME/profiles`; with no unambiguous profile the shipped base bundle
  defaults are used. The model id is `agent-default-model.config.model` (the
  shipped base bundle says `deepseek-flash`).
- The base URL is `llm-deepseek.config.baseURL`, else `DEEPSEEK_BASE_URL` from
  the DSH launch environment layers, else the adapter's public default.

The API key is only printed to stdout as `export PDSH_MODEL_API_KEY='…'` for
`eval`; it is never logged and nothing is written to disk. If the credentials
document is missing, the script prints a clear error naming the document path
and the expected `refs` entry and exits **3**; a document readable by
group/other is refused the same way (the provider refuses it before reading a
value). A missing/unbuilt checkout exits **2**. If the document exists but the reference is absent, the provider's
documented precedence is followed: the variable from the DSH launch environment
is used; if that is absent too, exit 3.

Because the Worker's packed profile is fixed, the Worker's DSH still sends its
own composed default model id (`deepseek-flash` for the pinned base bundle).
`PDSH_MODEL_NAME` is recorded and exported for diagnostics; a resolved model id
different from the packed default is a configuration mismatch reported by the
run, not silently rewritten.

## Catalog schema

Read by `Sources/PhoneDSHScenario/ScenarioCatalog.swift` (shared
by the macOS and iOS Simulator suites). Unknown top-level and scenario fields
are ignored, but **assertion objects are strict**: see "Strict assertion
schema" below. JSON contains no comments.

```json
{
  "version": 1,
  "generated_by": "...",
  "scenarios": [{
    "id": "G2-A01",
    "category": "files",
    "title": "short title",
    "user_story": "one sentence",
    "workspace": {
      "files": { "relative/path.txt": "content" },
      "fixture": "cart-bugs"
    },
    "turns": [{ "prompt": "what the user types" }],
    "assertions": [
      { "type": "file_exists", "path": "a.txt" },
      { "type": "file_contains", "path": "a.txt", "value": "hello" },
      { "type": "file_regex", "path": "a.txt", "value": "hel+o" },
      { "type": "file_json_path", "path": "out.json", "value": "totals.error" },
      { "type": "no_file", "path": "old.txt" },
      { "type": "workspace_command", "command": "python3 -m unittest" },
      { "type": "turn_count_lte", "max": 3 },
      { "type": "no_console_error" },
      { "type": "restart_recovered" }
    ],
    "rubric": ["qualitative review criterion for the judge"],
    "budget": { "max_minutes": 10, "max_model_requests": 25 },
    "perturbations": [{ "at": "after_turn:1", "kind": "planned_restart" }],
    "network": "none",
    "tags": ["files", "multi-turn"],
    "target": "both"
  }],
  "fixtures": [{ "name": "cart-bugs", "description": "..." }]
}
```

- `workspace.fixture` is copied from `fixtures/<name>/`; `workspace.files`
  overrides or adds files afterwards. Seeding goes through the real
  `WorkspaceLog` VFS path, not a host filesystem copy, so the Worker sees a
  normal materialized workspace.
- `network` is `"none"` (only the model host is reachable through the host
  gateway) or `{"allow": ["host", ...]}`. Allowed non-model hosts get an
  anonymous credential; the model key is only served for the model host.
- `target` values: `macos`, `sim`, `both`.
- `assertions`:
  - `file_exists` / `no_file` — path in the materialized workspace.
  - `file_contains` / `file_regex` — text/regex on a materialized file.
  - `file_json_path` — `path` is the JSON file, `value` is a dot/bracket path
    (`totals.error`, `items[0].name`); passes when the path resolves and is not
    null.
  - `workspace_command` — run by `/bin/bash` in a throwaway copy of the
    materialized workspace; `/dsh/workspace` in the command is rewritten to
    that copy. Exit 0 passes. On the iOS Simulator this is a two-phase
    assertion (see below): the simulator records it as `pending_host` and the
    host driver evaluates it on the Mac after pulling the results.
  - `turn_count_lte` — delivered scenario-turn count must not exceed `max`.
    Each planned turn contributes at most one, even if the driver retries it;
    the detail separately reports DSH `turn/start` events including retries.
    This observed counter is evaluated even when a delivered turn ends in
    error, because the count is still known. Use `model_requests_lte` to bound
    retries/model attempts.
  - `model_requests_lte` — gateway attempts that asked the host credential
    provider for the model host (retries included) must not exceed `max`; the
    stall self-test uses it to prove a delivery timeout is not retried.
  - `no_console_error` — no error-level Worker console line, host error event or
    harness error status during the run.
  - `session_error` — an error-level Worker console line, host error event or
    harness error status was recorded; `value` optionally narrows the match to a
    substring (for example the typed `PDSH_DELIVERY_TIMEOUT` marker). Use it when
    the expected outcome is a fail-loud error rather than a clean turn.
  - `restart_recovered` — every perturbation point that was reached returned the
    host to Running with the acked materialized files unchanged.
- `perturbations.at`: `after_turn:<n>` (after the nth turn), `during_first_tool`
  (when the first tool call is observed) or `minute:<n>` (n minutes after the
  scenario starts). `kind`: `planned_restart`,
  `park_resume`, `worker_kill`, `webcontent_kill`.
- `mock` (optional, `--upstream mock` only) scripts the mock upstream reply
  shape: `tool_call_rounds` replies call the fixed `bash` tool before the final
  text reply; `response_bytes` is the target SSE body size per reply (the last
  value repeats, default is the 15–95 KB shape observed in the real batch);
  `chunk_bytes`/`chunk_delay_ms` control how the body is streamed.
  `stall_from_response` (1-based reply number) and `stall_after_bytes` make the
  server write part of the body and then hold the socket open with no
  terminating chunk — the delivery-stall shape seen in the real batch.
  `resume_after_ms`, when set with the stall options, delivers the remaining
  body after that pause instead of holding the socket forever. The host gateway
  already owns the complete body; this is the shape of a downstream consumer
  that stopped pulling for a while, which the delivery layer must recover from.
  `delivery_idle_timeout_ms` sets the Worker host-route delivery inactivity
  interval for the run (default 60 s). This is test harness configuration, not a
  scenario branch in production code.

### Scenario resource budgets (G2-FIX-115)

A scenario may declare the resource premise its turns depend on in a
`budgets` block. The block is strictly decoded: an unknown key, a non-integer
value or a value outside the host contract range fails the catalog load with
the coding path, before any scenario runs. The runner never changes the host
defaults; it injects the declaration through the public
`PhoneDSHConfiguration.singleFileLimitBytes` field.

```json
{
  "id": "G2-EXAMPLE",
  "budgets": { "singleFileBytes": 16777216 },
  "turns": [{
    "prompt": "…the single-file limit here is {{budgets.singleFileBytes}} bytes ({{budgets.singleFileMiB}} MiB)…"
  }],
  "assertions": [{
    "type": "workspace_command",
    "command": "python3 -c \"… size <= {{budgets.singleFileBytes}} …\""
  }]
}
```

- Supported key and range: `singleFileBytes`, 16 MiB … 128 MiB
  (`BudgetTable.minimumSingleFileLimitBytes`…
  `BudgetTable.absoluteMaximumSingleFileBytes`). The host's tier gate still
  applies when the configuration is built; a declaration the gate would clamp
  fails the run loudly.
- The declaration is the **single source** for limit figures in `title`,
  `user_story`, `turns[].prompt`, `assertions[].value`,
  `assertions[].command` and `rubric[]`. The load-time expansion recognises only
  the explicit `budgets.` namespace, so fixture text that legitimately contains
  `{{name}}` placeholders is untouched. Known references:
  `{{budgets.singleFileBytes}}` (decimal bytes),
  `{{budgets.singleFileBytesGrouped}}` (`16,777,216`) and
  `{{budgets.singleFileMiB}}` (whole MiB only). A reference without a
  declaration or an unknown reference fails the load. The catalog on disk is
  the template: the runner resolves it when it loads the document, so a raw
  snapshot (`scenario.json`) keeps the references; the prompt sent over the
  harness and the assertion the runner evaluates always carry the resolved
  figures, and `report.json` records the resolved command and the budget
  provenance.
- After the host reaches `Running`, the runner reads the Worker-published
  `materialized/home/capabilities.json` and compares its
  `limits.single_file_bytes` with the declaration. `report.json` carries the
  machine-checkable provenance on every run that declared a budget:

  ```json
  "budgets": {
    "declared_single_file_bytes": 16777216,
    "host_configuration_single_file_bytes": 16777216,
    "effective_single_file_bytes": 16777216,
    "source": "host/materialized/home/capabilities.json",
    "matches": true
  }
  ```

  A host-configuration clamp, a missing manifest or a declared/effective
  mismatch fails the run loud (`BUDGET`/`ERROR`) with both values recorded, so a
  scenario can never silently measure the host default instead of its premise.
- `G2-A09` uses this path: it declares a 16 MiB cap, asks for a 20 MiB file
  (the write is refused with the structured `EFBIG`/`VFS_REFUSED` chain), then
  requires the data as two shards whose size is checked against the declared
  limit. The superseded 15 MiB D4 value no longer appears in the catalog.

### Strict assertion schema

Assertions are validated when the catalog is loaded, before any scenario runs.
Each assertion `type` has a fixed key set (`type` is always allowed):

| type | allowed keys | required keys |
|---|---|---|
| `file_exists`, `no_file` | `type`, `path` | `path` |
| `file_contains`, `file_regex`, `file_json_path` | `type`, `path`, `value` | `path`, `value` |
| `workspace_command` | `type`, `command` | `command` |
| `turn_count_lte`, `model_requests_lte` | `type`, `max` | `max` |
| `no_console_error`, `restart_recovered` | `type` | — |
| `session_error` | `type`, `value` | — |

An unknown key (for example `"3": 0` where `"max": 3` was intended), a missing
required key, or an unknown assertion type fails the load with an error naming
the scenario id, the 0-based assertion index, the type and the offending key:

```text
environment: scenario G2-E09 assertion[9] (type turn_count_lte):
unknown key "3"; allowed keys: max, type
```

A `turn_count_lte` or `model_requests_lte` without `max` never reaches
evaluation, and evaluation itself throws rather than substituting `Int.max`;
a typo can no longer become a silently true assertion.

Every `--upstream mock` report also carries an automatic `mock_delivery`
assertion: one usage event must exist for every complete scripted response, so
a response that reaches the host response log but never the Worker's model
client fails the run instead of passing silently.

### Delivery-window replenishment self-test

`G2-SELFTEST-DELIVERY-128K` streams five 30 KiB replies; the fifth pauses after
8 KiB for longer than the run's 1.5 s Worker delivery interval. The host
gateway still receives and commits the complete body (by design, a downstream
cancellation never cancels the upstream). The Worker's host-route wrapper then
re-fetches the same request with `x-pdsh-resume-from: <delivered bytes>`; the
gateway serves the suffix from its committed response log and never contacts
the upstream again. The `mock_delivery` assertion requires one usage event per
complete streamed response, so the pre-fix outcome is visible as
`4 usage event(s) for 5 complete streamed response(s)` plus
`PDSH_DELIVERY_TIMEOUT`; after the fix the turn finishes and `a.txt` exists.

```sh
bash scripts/ci/scenarios.sh --upstream mock --only G2-SELFTEST-DELIVERY-128K
```

The resume is bounded (`MAX_DELIVERY_RESUMES`) and keeps the typed
`PDSH_DELIVERY_TIMEOUT` failure when the host cannot serve the suffix, so the
stall self-test below still fails loud.

### Delivery fail-loud self-test

`G2-SELFTEST-DELIVERY-STALL` consumes one scripted reply, then stalls every
later reply after 8 KiB with a 2 s Worker-side delivery interval. The expected
result is a bounded run that ends with a session/host error event (the
`session_error` assertion) instead of a silent turn: the run report records the
stalled responses separately from the complete ones, and the automatic
`mock_delivery` count still covers the replies that did complete.

```sh
bash scripts/ci/scenarios.sh --upstream mock --only G2-SELFTEST-DELIVERY-STALL
```

This self-test intentionally ends its one delivered turn with a failure. The
report keeps `run_completed: false`, while `turn_count_lte` still evaluates
the observed delivered-turn count (one, within its max of two); the separate
`model_requests_lte` assertion checks that the delivery failure was not retried.

The delivery deadline is what makes that bounded. To reproduce the pre-fix
failure, run the same scenario with the Worker-side deadline neutralized: copy
`selftest.json`, set `delivery_idle_timeout_ms` above `max_minutes * 60_000`
(for example `600000`), and pass it with `--catalog <path>`. The stalled
response then never errors and no session error event is recorded, so the run
fails: on a visible page it reports `TIMEOUT` when the wall budget elapses; a
hidden/frozen page is caught earlier by the locked-screen guard. This stall
shape is the same one the real-model batch produced (`progress step N`, a
complete response in the host response log, no Worker consumption); the
real-model rerun of the affected catalog scenarios is an operator step on an
unlocked Mac with network access, not part of this mock self-test.

The CI gate runs the selection guard plus the healthy and fail-loud delivery
scenarios; the stall variant is expected to end with a fail-loud error event:

```sh
bash scripts/ci/scenarios.sh --upstream mock \
  --only G2-SELFTEST,G2-SELFTEST-DELIVERY,G2-SELFTEST-DELIVERY-STALL,G2-SELFTEST-DELIVERY-128K
```

### Two-phase `workspace_command` evaluation on the simulator

A `workspace_command` assertion needs to spawn `/bin/bash`; the iOS Simulator
test bundle cannot, because the test process is sandboxed and has no
`Process`. Evaluating it there would report the command as failed even when the
model's work is correct. Both runners therefore share one implementation
(`ScenarioWorkspaceCommand` in `Sources/PhoneDSHScenario`), and
`--run-on sim` splits the work into two phases:

1. **Simulator phase.** The iOS test process matches every assertion type as
   before, except `workspace_command`: it copies the command text into the
   assertion as `status: "pending_host"` and does not spawn or copy anything.
   If the only open item is such an assertion, the report status is the
   provisional `PENDING_HOST`; a settled failure still reports `FAIL`, and a
   terminal `TIMEOUT`/`BUDGET`/`ERROR` is unchanged. The simulator XCTest case
   treats `PENDING_HOST` as provisional and skips it, never as a pass.
2. **Host phase.** After `xcodebuild test` finishes, `scenarios.sh` pulls
   `Documents/pdsh-scenarios/results/<id>/` into `--results` and runs the same
   `ScenarioWorkspaceCommand.evaluateOrDefer` implementation on the Mac against
   the pulled materialized tree `<results>/<id>/host/materialized/workspace`
   (the authoritative copy; `workspace.tar` is the same tree archived before
   assertion evaluation). The command runs in `<results>/<id>/check-workspace/`
   with the same `/dsh/workspace` rewriting, `PATH`, 180 s watchdog and exit-0
   verdict as macOS. This is **host acceptance**, not Worker VFS execution:
   every detail carries one explicit line
   `[environment: host-bash; worker VFS: not used; path: /dsh/workspace -> <copy>]`.
   A command that references any other `/dsh/` path (`/dsh/home`, `/dsh/tmp`,
   ...) fails before the process starts with `worker_vfs_only`, because the Mac
   host has no such path and must not manufacture a fake `exit 0`.
   `report.json` is then rewritten in place: `ok`/`detail` are filled in, the
   assertion gets `status: "host_evaluated"`, `host_evaluated: true` and
   `duration_ms`, and the report gets top-level `host_evaluated: true`. The
   final status follows the macOS rule (`TIMEOUT`/`BUDGET`/`ERROR`/`SKIP` keep
   their precedence, otherwise any failed assertion is `FAIL` and a clean
   report is `PASS`).

The host phase is implemented by the `ScenarioHostEvaluation` library entry
called through a `ScenarioHostEvaluationTests` XCTest shim; `scenarios.sh`
invokes that shim only when a selected pulled report actually carries a
`pending_host` assertion. The report check prints the final status (and the
number of host-evaluated assertions) and its exit code follows that status: a
`PENDING_HOST` report is an un-finalized run and fails the gate, as does any
`FAIL`/`TIMEOUT`/`BUDGET`/`ERROR`. It reads only
`<results>/<selected-id>/report.json` and requires that document's `id` to
match the selected id; an unselected older report is ignored, and a report in
another directory cannot stand in for a selected scenario. `G2-SELFTEST` carries a `workspace_command`
assertion that reads the real materialized `a.txt` and seeded `README.md`, so
the CI gate exercises both phases.


### Page visibility, the event pump and the stall watchdog

A WKWebView page that WebKit considers hidden is frozen after a few seconds:
the Worker's fetch body, channel frames and DOM timers stop while no process
exits. Under `swift test` a page can be hidden even with the display on and the
screen unlocked: the XCTest process never runs `NSApplication.run`, so unless
its waits dequeue and dispatch AppKit events the ordered harness window never
becomes occlusion-visible and `document.visibilityState` stays `hidden`. That
is why the G2 real-model batch stalled at `progress step N` with a complete
response already in the host response log.

The runner therefore:

- uses one shared AppKit event pump (`WebEngineAppKitEventPump`) for every
  wait — boot, turns, perturbations, assertions — instead of a run-loop-only
  or `Task.sleep`-only wait;
- asserts the page-visibility precondition (`NSWindow.occlusionState` contains
  `.visible` **and** `document.visibilityState == "visible"`) before the first
  turn, failing loud with the sampled state instead of hanging, and records it
  as `page_visibility` in `report.json`;
- keeps the 12 s watchdog: when a turn has produced no harness event for 12 s
  the runner samples the same visibility signals and fails with an actionable
  environment error if the page is hidden or unresponsive. A locked or
  occluded screen still triggers this safety net; run the real-model batch with
  the screen unlocked (or with a user session that keeps it awake).

The component delivery deadline in `llm-bridge` additionally fails a stalled
response with `PDSH_DELIVERY_TIMEOUT`, so a live Worker never waits for the model
adapter's own idle watchdog. See `docs/architecture.md`, page visibility.

## Perturbations and what they mean here

- `planned_restart` — `PhoneDSHHost.plannedRestart(reason:)` (D24).
- `park_resume` — `PhoneDSHHost.park()` followed by `resume()`.
- `worker_kill` — the real page Worker execution context is terminated through
  a document-start user script that captures the `Worker` handle; the page
  itself cannot boot it again, so the host's standard restart path rebuilds the
  page and waits for the new HELLO. (The landed `WebEngine` has no public
  terminate-worker API; killing only the thread without the host restart leaves
  a dead stack, so the runner pairs the two.)
- `webcontent_kill` — on macOS the runner SIGKILLs the WebContent process that
  was created for this run's WKWebView. Identification is evidence-based, never
  by name across the host: a cross-process file lock serializes WKWebView
  boot/restart while each lane takes a baseline of macOS WebContent PIDs, and
  only a `com.apple.WebKit.WebContent` process that appeared inside that locked
  window is selected (simulator WebContent processes are excluded). The
  selected PID is refreshed after every perturbation and killed at scenario
  teardown so the next scenario starts from a fresh process.

  On the iOS Simulator the test process cannot signal a host process, so
  `scripts/ci/scenarios.sh --run-on sim` arms the device-scoped
  `scripts/ci/webcontent-watch.sh` before the run and exports
  `PDSH_SCENARIO_WEBCONTENT_WATCH=1` (through the test-runner environment). The
  runner writes a `<token>.request` handshake under
  `results/.webcontent-kill/`; the watcher SIGKILLs the selected simulator's
  newly appeared WebContent pid and writes `<token>.result`. `sim.sh` calls the
  same watcher for its smoke INFO row.

  The capability matrix is declared per execution target and validated when
  the catalog is loaded, **before any scenario starts**:

  | target | planned_restart | park_resume | worker_kill | webcontent_kill |
  |---|---|---|---|---|
  | macOS `swift test` | yes | yes | yes | yes (host SIGKILL) |
  | iOS Simulator | yes | yes | yes | only with the armed watcher |
  | iOS device | yes | yes | yes | no (no device watcher exists) |

  An unexecutable declaration aborts that scenario as an explicit runner-INFRA
  result: report status `INFRA`, every declaration listed in `perturbations`
  with `status: "runner_infra"`, and **no assertion is evaluated** — so a
  capability gap can never be reported as a `restart_recovered` product
  failure. `scenarios.sh` prints a `RUNNER-INFRA:` line and exits 6 for that
  batch (product verdicts keep exit 5). Nothing is silently skipped.

## Result artifacts

`<results>/<id>/`:

- `report.json` — `{id, status: PASS|FAIL|TIMEOUT|BUDGET|ERROR|INFRA,
  assertions:[{type,ok,detail,status?,command?,host_evaluated?,duration_ms?,
  worker_evaluated?,worker_receipt?,program?,cwd?,timeout_ms?}],
  turns:[{prompt_len,started,ended,
  model_requests,tool_calls,events}], perturbations:[{at,kind,recovered_ms,ok,
  status?,mechanism?,killed_pids?,detail?}],
  usage:{model_requests,upstream_bytes_in,upstream_bytes_out,wall_s},
  console_errors:[...], runner_errors:[...], host_states:[...],
  host_evaluated?}`. `INFRA` and the
  `status`/`mechanism`/`killed_pids` perturbation fields are additive
  (G2-FIX-65): an INFRA report aborts before the product runs and carries
  `runner_infra`; applied perturbations keep the existing recovery verdict.
  The new optional fields are additive: assertion `status`/`command`/
  `host_evaluated`/`duration_ms` and the report-level `host_evaluated` appear
  only when a `workspace_command` assertion ran on a Mac host (the macOS
  runner, or the simulator host phase); the judge and the batch orchestrator
  need no change. A `worker_command` assertion additionally carries
  `worker_evaluated`, the raw `worker_receipt`, and the effective request facts
  `program`/`cwd`/`timeout_ms`; the evidence gate requires the receipt's
  frozen fork and `execution` facts to match those declarations, and a failed
  execution can never be `ok: true` (see
  the plugin tests).
  `console_errors` is one source of truth: it carries **only** the
  Worker/session console-error stream, the exact array `no_console_error` and
  `session_error` evaluate. Runner lifecycle diagnostics — a deferred run, a
  runner-INFRA abort, the timeout/budget/other terminal error that ended the
  run — are in `runner_errors` and never make `no_console_error` fail. Before
  G2-FIX-4 both went into `console_errors`, so a timed-out report could say
  `no_console_error: ok` beside its own `runner: timeout: ...` entry.
  On the simulator the intermediate status `PENDING_HOST` is provisional and
  never survives into a pulled final report.
- `transcript.jsonl` — every harness event, one JSON object per line, redacted.
- `workspace.tar` — the materialized `workspace/` tree after the run.
- `bodies/` — only when `PDSH_SCENARIO_KEEP_BODIES=1`: redacted model request
  bodies and SSE responses for the mock upstream, or the gateway's bounded
  response-log bodies for a real run (request bodies are not exposed by the host
  gateway). Redaction removes `Authorization`/`x-api-key` values and anything
  matching `sk-[A-Za-z0-9]{8,}`.
- `host/` — the WAL, materialized copy and response log of the run; kept for
  diagnosis. On the simulator the pulled
  `host/materialized/workspace/` is the input of the host phase.
- `check-workspace/` — the copy `workspace_command` assertions ran in (created
  by the macOS runner, or by the host phase after a simulator run is pulled).
  A command rejected as `worker_vfs_only` creates no copy and executes nothing.
- `scenario.json` — the redacted scenario definition this attempt ran, written
  before the host boots.
- `history/a<NNN>/` — frozen earlier attempts. `scenarios.sh` archives the
  current attempt before a rerun can overwrite it, and never reuses an existing
  attempt directory. Each archive holds the moved `report.json`,
  `transcript.jsonl`, `workspace.tar`, `host/`, `check-workspace/`, `bodies/`,
  `scenario.json` and `attempt.json`.
- `evidence_missing.json` — written by `scenario_evidence.py verify` when a
  terminal run is missing required evidence (see below); absent on a complete
  attempt.

`usage.model_requests` counts gateway attempts that asked the host credential
provider for the model host (retries included). `upstream_bytes_out` is the
mock's response bytes or the real run's bounded response-log bytes;
`upstream_bytes_in` is only measurable for the mock upstream (real request
bodies are not exposed), so a real run reports 0 there rather than an estimate.
`report.json` is still written for `TIMEOUT`/`BUDGET`/`ERROR`; a scenario whose
assertions fail reports `FAIL` and fails its XCTest case without stopping the
batch (one test case per scenario).

### Attempt history and the capability index (G2-FIX-72/123, ENG-06)

Every `scenarios.sh` run is one attempt. Before `swift test` starts (the Swift
runner deletes its own artifacts in `prepareDirectories`) and before the
simulator pull merges its results, the driver archives the current attempt:

```text
<results>/<id>/history/a001/
  report.json  transcript.jsonl  workspace.tar  scenario.json
  host/  check-workspace/  bodies/
  attempt.json
```

`attempt.json` freezes the attempt number, status, usage, the judge snapshot
(the redacted `report.judge` or `judge.json`) and the archive time, with paths
relative to `--results` (for example, `G2-X/history/a001/report.json`). The
driver then clears only the mutable current artifacts; `history/` and the index
survive. A rerun therefore never turns the previous status/usage/judge into the
new run's evidence.

Attempt numbers come from the index's persistent `next_attempt` counter. The
archive command reserves the number before it moves the report and advances the
counter, so deleting old `history/a<NNN>/` directories cannot make the next
attempt reuse a number. The current attempt keeps its already assigned number
when it is finally archived. If a runner leaves only partial artifacts and no
`report.json`, those artifacts are still preserved under `history/` with an
`UNKNOWN` attempt record, but the index remains `CLEARED` with no report path;
`ARCHIVED` is reserved for a frozen report that actually exists.

`<results>/.capability-index.json` is refreshed from the current `report.json`
after every run, again after the simulator pull (before the host phase, so a
git repair is in place for `workspace_command`), and once more after the host
phase for the final status:

```json
{
  "version": 1,
  "updated_at": "2026-01-01T00:00:00Z",
  "scenarios": {
    "G2-A01": {
      "current": {
        "state": "CURRENT",
        "attempt": 2,
        "status": "PASS",
        "usage": {"model_requests": 8},
        "judge": null,
        "paths": {"directory": "G2-A01", "report": "G2-A01/report.json",
                  "history": "G2-A01/history",
                  "index": ".capability-index.json"}
      },
      "attempts": [
        {"attempt": 1, "status": "FAIL", "usage": {"model_requests": 7},
         "judge": null, "archived_at": "2026-01-01T00:00:00Z",
         "path": "G2-A01/history/a001"}
      ],
      "next_attempt": 3
    }
  }
}
```

`current.state` is `CURRENT` while the run's report is the live attempt,
`ARCHIVED` after the report moved under `history/` (the report path then points
at that frozen file and `current.paths.directory` is the frozen
`<id>/history/a<NNN>` directory), and `CLEARED` when only the mutable current
artifacts were removed. The archive command writes a safe `PENDING` state before
it moves anything, so an early exit (a failed build or a runner that never
writes a report) cannot leave `current.paths.report` pointing at a moved-away
file. A finalize after the archive but before a new report re-derives the frozen
attempt from `current.paths.report` (so older indexes that still stored the live
directory are healed) and keeps the frozen report/transcript/host paths instead
of mixing in partial live artifacts; if that frozen report was garbage
collected, the entry becomes `CLEARED` with no report path. `clear-current`
persists a safe `PENDING` marker with no artifact paths before its first
`unlink`/`rmtree` and writes `CLEARED` only after the removal, so an interrupted
clear also cannot leave a dangling report path. Artifact entries are emitted
only when they exist; `ARCHIVED` and `CLEARED` never claim a live
`<id>/report.json`.

All paths are relative to `--results`; status/usage/judge are the only run
data copied into the index, and host absolute paths and credential-shaped
strings are redacted. The current report is augmented with
`attempt` (the number), `attempt_snapshot` (number, relative history paths,
index path) and, when a repair happened, `staging_repairs`, so the report and
the index agree on which attempt they describe.

### Terminal evidence verification (G2-FIX-128)

After the run (and after the simulator host phase) `scenario_evidence.py verify`
requires the selected scenario's terminal evidence without fabricating any of
it:

- `PASS`, `FAIL`, `TIMEOUT`, `BUDGET`, `ERROR` (and an un-finalized
  `PENDING_HOST`) require `report.json`, `transcript.jsonl`, `workspace.tar`,
  `host/materialized/workspace/`, `host/wal/`, `host/journal.xljournal`,
  `host/response-log/`, `host/fence.json` and at least one
  `host/overlay-*.tar`.
- `SKIP` and `INFRA` require `report.json`, `transcript.jsonl` and
  `scenario.json`; the host artifacts and `workspace.tar` are recorded as
  `not_applicable` with the deferred status as the reason.

A missing required artifact writes `evidence_missing.json` with the exact
relative paths and makes `scenarios.sh` exit non-zero, so an aborted
`TIMEOUT`/`ERROR` can never look complete.

The report itself is validated against the runner schema before evidence is
accepted: a JSON `[]`, `null` or string, an unknown `status`, a report
missing `id`/`status`/`assertions`/`turns`/`perturbations`/`usage`/
`console_errors`/`host_states`, or a report whose `id` is not the selected
scenario is a `REPORT_STRUCTURE` failure, never an `UNKNOWN` pass. The batch
report check uses the same validator on the selected scenario's own
`<results>/<id>/report.json` (unselected directories are not read) and keeps
the clearer exits: `4` for an unusable/missing report tree, `5` for a real
scenario verdict (`FAIL`/`TIMEOUT`/`BUDGET`/`ERROR`/`PENDING_HOST`), and `6`
for runner-INFRA. Exit `6` is a classification, not a product verdict, and
deliberately overrides the generic non-zero XCTest exit produced by the slot
glue; otherwise the INFRA contract above could never reach the batch. Exits
`4`/`5` replace an evidence-only exit `1` (including a failed provisional
finalize on the simulator), but a real runner/build/xcodebuild/xctest failure
keeps its own non-zero code. A report-check self-error (`1`) never hides that
runner code.

### Pulled `.git` repair (G2-FIX-110)

`workspace.tar` is the evidence of record. The host phase must evaluate the
same materialized tree that was archived, including a fixture's `.git/`, or a
git-dependent `workspace_command` result is not reproducible. After the pull and
before the host phase evaluates any `workspace_command`,
`scenario_evidence.py` reads the tar with the Python stdlib `tarfile` module:

- if the tar contains `.git/` but the pulled
  `host/materialized/workspace/` or `check-workspace/` lost it, only `.git/`
  is extracted into that tree; non-`.git` files are never overwritten, and the
  repair is listed in `report.json`'s `staging_repairs`;
- absolute paths, `..` traversal, hard links and escaping symlink targets are
  rejected before extraction;
- if the scenario is a git fixture (or the caller passes `--require-git`) and
  neither the tar nor the materialized tree has `.git/`, finalization and
  verification fail loud with a `G2-FIX-110` marker. No git history is ever
  invented.

Budget rules: `budget.max_minutes` is wall clock from scenario start (boot
included). When it elapses the running turn is cancelled and the status is
`TIMEOUT`. When the model-request count exceeds `budget.max_model_requests` the
turn is cancelled and the status is `BUDGET`.

## Fixtures

`fixtures/<name>/fixture.json` describes a fixture's deterministic git history:

```json
{
  "name": "notes-legacy",
  "description": "...",
  "git": {
    "branch": "master",
    "identity": { "name": "phone-fixture", "email_user": "dev", "email_host": "example.invalid" },
    "commits": [
      { "message": "initial", "files": ["notes.py", "README.md"] }
    ]
  }
}
```

The runner builds the repository with plumbing commands (`git init`,
`git add`, `git write-tree`, `git commit-tree`, `git update-ref`; no
`git commit`, `checkout`, `branch` or `reset`) in a scratch directory and then
seeds every file, `.git` included, through the VFS WAL. A fixture with an
`identity` gets a local `user.name`/`user.email` in `.git/config` (the Worker
git has no `git config` subcommand); a fixture without one deliberately has no
identity configured. Fixture payloads are checked in under
`fixtures/<name>/files/`; commit-history metadata is in `fixture.json`.

## Not verified / limitations

- The runner executes on macOS WKWebView and on the iOS Simulator
  (`--run-on sim`, `PhoneDSHScenarioSimTests`). Nothing in this runner has run
  on a physical iPhone; the device branch of the host driver and all device
  behaviour remain `NOT_VERIFIED`.
- Fixtures with deterministic git history are built inside the macOS test
  process; the simulator host driver builds the same history host-side while
  staging and ships it inside the staged `files/` tree (the test process is
  sandboxed and cannot spawn `git`). Both runners therefore seed the same
  repository contents through the WAL.
- On the simulator, `workspace_command` assertions are evaluated in the host
  phase after the results are pulled (see above); the simulator test bundle
  spawns no process. The physical-device branch has not been run, so its host
  phase is `NOT_VERIFIED` like the rest of the device path.
- The captured simulator evidence carries `host/materialized/workspace/`; the
  host phase uses that tree. `workspace.tar` is written just before assertion
  evaluation and holds the same tree, but it is not extracted by this driver.
- The real-model batch itself was not executed by the runner package (no
  credentials are available to the implementation worker). The self-test gate
  uses the scripted mock upstream. After the fix merges, the batch operator
  reruns the affected real-model scenarios on an unlocked Mac with network
  access; the stall self-test above and the delivery deadline are the mock-side
  regression for that class of failure.
- The `scenario_batch.py` plan/run/resume/summary contract is exercised on
  Linux with real temporary result trees and a fake lane runner; the actual
  macOS, iOS Simulator and real-model batch is **NOT_RUN** here. The
  56/835/2540 figures are catalog declarations, not measured wall/request usage.
- The mock upstream answers every user turn with the same fixed tool call and
  final message; it is only meant for the self-test and CI plumbing.
- `worker_kill` is the page Worker terminate plus the host restart described
  above, because the landed engine exposes no terminate-worker API.
- The Worker's packed profile fixes the DSH default model row; a `model-env`
  model id that differs from `deepseek-flash` is recorded but not injected into
  the Worker.
- One test process supports up to 64 selected scenarios (the fixed slot bank);
  the current catalog has 56. A larger selection is rejected as a whole before
  any scenario executes: the selection guard fails and every slot skips, so
  neither runner can silently drop or partially execute scenarios. The shared
  capacity check is `ScenarioSlotPlan.capacityError`; the contract regression
  test pins the slot bank to the shipped catalog.
- `network` scenarios need the host gateway allow-list and the gateway still
  injects the credential reference per upstream attempt; non-model public hosts
  receive an anonymous (`.none`) credential. Hosts outside the list fail with a
  gateway error, which a scenario rubric may require the model to report
  honestly.
