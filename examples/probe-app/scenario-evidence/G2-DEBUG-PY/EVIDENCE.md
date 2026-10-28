# G2-DEBUG-PY rerun evidence (G2-FIX-54 repair round)

A focused two-turn probe that asserts the exact G2-B04 acceptance wording
inside the rebuilt Worker. It is not a catalog scenario; it was run through the
same `scripts/ci/scenarios.sh --run-on sim` pipeline with a temporary
catalog, after the probe asset staging fix.

- `report.json`: `PASS` (`3/3` assertions: `no_console_error`,
  `turn_count_lte`, `restart_recovered`).
- Turn 1 (`19:20:21Z`) runs `ls -la /dsh/workspace`, which is the
  `during_first_tool` perturbation point; the host parks and resumes the Worker.
- Turn 2 starts at `19:20:43Z`, i.e. after the
  `controller:parked->recovering` / `recovering->running` cycle, and at
  `19:20:44Z` runs:
  `python3 -c "import os; print('cwd=' + os.getcwd()); print('hello_exists=' + str(os.path.exists('/dsh/workspace/hello.py'))); print('list=' + str(sorted(os.listdir('/dsh/workspace'))))"; python3 -c "import unittest; print('unittest-import-ok')"`
- The line-73 result is the acceptance evidence:
  `cwd=/dsh/workspace hello_exists=True list=['hello.py', 'test_smoke.py'] unittest-import-ok`

`report.json` and `transcript.jsonl` are unmodified runner outputs; `catalog.json`
is the temporary one-scenario catalog used for the run (the repository catalog
is unchanged).
