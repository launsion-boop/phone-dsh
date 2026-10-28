# G2-D06 rerun evidence (G2-FIX-54 repair round)

Real-model `G2-D06` run (long-run documentation-site scenario) on the iOS
Simulator runner, after the probe asset staging fix.

- `report.json`: `19/26` assertions pass. All `file_exists` / `file_regex`
  assertions pass; the seven `workspace_command` assertions fail only because
  the simulator test process cannot spawn `/bin/bash`.
- `worker_kill during_first_tool`: turn 1 ends `cancelled`, the host repeats
  the Worker lifecycle (`recovered_ms: 324`), and turn 2 starts at
  `19:12:24Z`. `transcript.jsonl` line 40 (turn 2, `19:12:52Z`) runs
  `python3 -m unittest discover ... -v`; line 41 is `isError: false` and the
  parse tests are green -- python3 sees the workspace after the kill.
- `planned_restart after_turn:2`: the harness records
  `recovered_ms: 20451`, turn 3 starts at `19:12:57Z`, and line 226
  (`19:13:36Z`) runs `python3 build.py` successfully (four site HTML files),
  followed by `python3 -m unittest ...` at line 240 (six tests green). The git
  commits required by the scenario are also made after this rebuild.
- The scenario's third perturbation, `webcontent_kill after_turn:3`, is
  reported `ok: null`: the simulator test process cannot signal the host
  WebContent process (the device-scoped watcher in `scripts/ci/sim.sh`
  remains the only real WebContent killer). `restart_recovered` therefore
  fails by runner construction, not because state was lost.

No `Traceback`, `cwd=/` or `ENOENT` appears in the transcript. `report.json`
and `transcript.jsonl` are unmodified runner outputs.
