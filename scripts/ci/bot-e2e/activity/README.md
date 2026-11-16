<!-- SPDX-License-Identifier: MIT -->
# Bot real-activity scenarios (activity-evidence-v3.1)

This directory holds the reproducible real-model acceptance input for the iOS Bot
activity bubble. It reuses the existing Bot eval harness; no second harness or fixture
framework is introduced.

- `catalog.json` (guided): three controlled Bot tasks (#174 merge check, Wednesday meeting
  summary, local email draft). The seed files are inline under each scenario's
  `workspace.files`; there is no network, mail account or send tool. The prompts ask for a
  short progress sentence after each read and force a two-read sequence. This proves the
  guided behaviour only.
- `catalog-natural.json` (natural control): the same seeds and tasks, but the user prompt
  gives only the task and the material location. It contains no 10–20 character progress
  instruction, no fixed read count and no output-format instruction. Tools are free; the
  receipt verifies that the real session actually read the seed (read or bash).
  **Current status: PASS on head `cefff6a2`.** All 3 natural scenarios passed; every
  session read its seeds with `bash`/`read` (no identity rejection), and every
  `request/header` says Flash/max. The small observed sequence has 16 unique activity
  details, 6 short basename fallbacks (37.5%), 8 model/tool-description details and 2 card
  labels; ACT-06 shows a real post-result Chinese continuation. The default prompt still
  produced several English `bash.description` lines and object fallbacks because the
  per-call description ranks first; that is recorded as a quality observation, not hidden.
  Earlier blocked attempts on head `91a26c50c` (wall-clock gateway expiry, the meeting
  false weak-regex PASS and the NOT_RUN email) are retained in
  `receipt.json.failedAttempts`; the clock fix is `cefff6a2`.
- `receipt.json`: the accepted actual activity sequence, with source seq/tool, raw model
  sentence, displayed detail, length/CJK count, object and result-continuation judgment,
  plus the model configuration read from `request/header`.

## Run

```bash
export DSH_HOME="<the running DSH home>"
export DSH_PROFILE=web
export PDSH_DSH_CHECKOUT="<the pinned DSH checkout>"
eval "$(node scripts/ci/model-env.mjs)"
export PDSH_MODEL_NAME=deepseek-flash
# The eval runner also pins this existing non-secret provider document; keep the
# explicit export so an operator can see the requested effort. Production defaults
# are not changed.
export PDSH_MODEL_PROVIDER_JSON='{"version":1,"selectedId":"eval","providers":[{"id":"eval","reasoningEffort":"max"}]}'
unset PDSH_DSH_WWW PDSH_DSH_IMAGE
export PDSH_BOT_EVAL_BUILD_DIR="<build cache>"
export PDSH_BOT_EVAL_SCRATCH="<SwiftPM scratch>"
bash scripts/ci/bot-e2e/eval.sh \
  --catalog scripts/ci/bot-e2e/activity/catalog.json \
  --upstream real --repeat 1 --keep-bodies --results "<guided results dir>"
# Then the natural control, reusing the same packed Worker and Swift scratch:
bash scripts/ci/bot-e2e/eval.sh \
  --catalog scripts/ci/bot-e2e/activity/catalog-natural.json \
  --upstream real --repeat 1 --keep-bodies --results "<natural results dir>"
```

The command packs the Worker bundle from this checkout and runs the production Bot
composition on the DSH runtime. A PASS requires each scenario's real tool calls and
reply assertions. Inspect each run's
`runs/<SCENARIO>-1/host/materialized/<dsh-home>/sessions/.../gb-main/session.v4.jsonl` and
confirm `request/header.data.header.config` says `provider=deepseek-official`,
`model=deepseek-flash`, `reasoningEffort=max`.

## Replay through the production reducer

`BotActivityReplayTests` in `scripts/ci/bot-e2e/harness/Tests/BotEvalTests` parses a real
DSH v4 session log with the production decoder, folds it through the production
`BotRuntimePresentationFactory` and `BotActivityEvidence.lineActivity`, prints each real
activity sentence, and fails on an empty log or a non-max header.

```bash
PDSH_ACTIVITY_SESSION="<.../gb-main/session.v4.jsonl>" \
  swift test --package-path scripts/ci/bot-e2e/harness \
  --filter BotActivityReplayTests
```

`receipt.json` records the accepted head/tree and sequences. Raw session logs and Worker
bundles stay local and are not committed.
