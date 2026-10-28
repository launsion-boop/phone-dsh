# Scenario rerun evidence (G2-FIX-54 repair round)

Captured real-model runs of the scenarios affected by the Worker-rebuild python
toolbox defect. They were produced by the repository's normal simulator
pipeline after fixing the probe asset staging gap: the iOS app bundle now
receives `tool-worker-python.js` from the standard Worker build, so `python3`
can start in every rebuilt Worker. No asset was injected by hand.

| directory | scenario | rebuild exercised | post-rebuild python3 | report |
|---|---|---|---|---|
| `G2-B04/` | `G2-B04` refactor + `park_resume` | park/resume | `python3 -m unittest discover -v` (10 tests green), `python3 main.py` | FAIL (runner-side assertions only; see below) |
| `G2-B03/` | `G2-B03` debug + `worker_kill` | Worker kill | `python3 -m unittest && python3 run.py` green | FAIL (runner-side assertions only; see below) |
| `G2-D06/` | `G2-D06` long-run + `worker_kill`, `planned_restart` | Worker kill, planned restart | `python3 -m unittest`, `python3 build.py` green after each rebuild | FAIL (runner-side assertions only; see below) |
| `G2-DEBUG-PY/` | focused file-view probe + `park_resume` | park/resume | `cwd=/dsh/workspace`, `os.listdir('/dsh/workspace')` works, `os.path.exists` true, `import unittest` ok | PASS 3/3 |
| `staging-repair/` | component test of both asset staging steps | n/a | before: 0/4, after: 4/4 | n/a |

The `staging-repair/` directory keeps the failing-before / passing-after output
for the asset chain that made the earlier reruns impossible.

## Why the scenario reports still say `FAIL`

The iOS Simulator test process cannot spawn host processes
(`ScenarioProcess.run` is compiled for macOS only), so every
`workspace_command` assertion reports `exit -1: host process execution is not
available in the iOS scenario runner`. That is a limitation of the runner, not
of the python toolbox, and it applies to every python scenario on this runner.

`G2-B04`'s `restart_recovered` also compares a workspace snapshot taken while
turn 1 is still writing against the state immediately after resume; the model's
own acked turn-1 edits land in that window and are reported as "changed". The
transcript shows those files are the model's acked writes, not lost state.
`G2-D06` declares a `webcontent_kill` the simulator runner cannot apply (it
reports `ok: null` with an explicit detail), so its `restart_recovered` verdict
is false by construction.

The behaviour these reruns had to prove -- python3 sees the same `/dsh`
workspace as bash after a rebuild, and the full suite runs green again -- is in
each transcript. `G2-DEBUG-PY` was added as a focused two-turn probe because it
can assert the exact acceptance wording (`cwd`, `os.listdir`, `os.path.exists`)
in a second turn that starts only after the park/resume recovery.

All runs used:

```bash
export PDSH_DSH_CHECKOUT="${PDSH_DSH_CHECKOUT:-$(cat "$HOME/.config/phone-dsh/dsh-checkout")}"
eval "$(DSH_PROFILE=web node scripts/ci/model-env.mjs)"
bash scripts/ci/scenarios.sh --run-on sim --upstream real \
  --only G2-B04 --results "$TMPDIR/pdsh-scenarios-g2-b04"
```

The probe project is generated from `project.yml`, so `xcodegen` must be on
`PATH`; the flow fails loud when it is missing. `report.json` and
`transcript.jsonl` in each directory are unmodified runner outputs.
