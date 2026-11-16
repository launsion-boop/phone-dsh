# bot-aha evaluation layer

Reuses the existing production-assembly runner (`scripts/ci/bot-e2e/eval.sh`);
does not boot a second Bot. See
[`docs/evals/aha-multiturn-eval.md`](../../../docs/evals/aha-multiturn-eval.md)
for the normative description, scenarios, dimensions and anti-cheat rules.

```
aha_catalog.json     # 9 multi-turn scenarios, existing bot-e2e catalog schema
aha_dimensions.json  # independent scoring map (assertion index + type)
run.sh               # eval.sh -> score.py (adds --keep-bodies)
score.py             # reads report.json / transcript.jsonl / bot-events.jsonl
compare.py           # baseline vs candidate; INCOMPARABLE on config drift
tests/               # mutation tests: mock/missing/drift/regression never pass
```

Quick checks (no Worker, no model):

```sh
python3 -m unittest discover -s scripts/evals/bot-aha/tests
python3 scripts/ci/bot-e2e/eval_catalog.py plan \
  --catalog scripts/evals/bot-aha/aha_catalog.json \
  --results /tmp/aha-plan --plan-out /tmp/aha-plan/.plan.json \
  --repeat 1 --upstream mock
```

Real run: `eval "$(node scripts/ci/model-env.mjs)"` then
`bash scripts/evals/bot-aha/run.sh --upstream real`. A mock run is `NOT_RUN`
in the aha score by design.
