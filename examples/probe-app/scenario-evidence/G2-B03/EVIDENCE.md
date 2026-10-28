# G2-B03 rerun evidence (G2-FIX-54 repair round)

Real-model `G2-B03` run (`sensor-log` fixture, `worker_kill` during the first
tool call) on the iOS Simulator runner, after the probe asset staging fix.

- `report.json`: `3/5` assertions pass. `restart_recovered`, `no_console_error`
  and `turn_count_lte` pass; the two `workspace_command` assertions fail only
  because the simulator test process cannot spawn `/bin/bash`.
- The perturbation is `worker_kill at during_first_tool`: turn 1 ends
  `cancelled` at `19:11:50Z`, the host repeats the
  `running->draining->parked` / `parked->recovering->running` cycle
  (`recovered_ms: 337`), and turn 2 starts at `19:11:50Z`.
- `transcript.jsonl` line 32 (turn 2, `19:11:57Z`):
  `python3 -m unittest && python3 run.py`
  line 33 is `isError: false` with the expected sensor summary and Fahrenheit
  output -- i.e. python3 finds and runs the workspace after the Worker kill.
- Line 202 runs `python3 run.py sample.log` in turn 3, also green.

No `Traceback`, `cwd=/` or `ENOENT` appears in the transcript. `report.json`
and `transcript.jsonl` are unmodified runner outputs.
