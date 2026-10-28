# Probe asset staging: before/after (G2-FIX-54 repair round)

The real-model scenario batch could not run `python3` in the iOS probe app
because neither the simulator staging step nor the app-copy step copied the
dedicated python tool worker (`tool-worker-python.js`) into the app bundle.
`python3` was published in the toolbox but its nested Worker 404'd, so every
python command hung; the previous round worked around it by injecting the file
by hand instead of fixing the pipeline.

This directory keeps the failing-before / passing-after output of the
component-level regression test that covers both steps
(`plugins/tests/probe-asset-staging.test.ts`).

- `before-fix-staging.log` -- the four tests run against the previous
  `scripts/copy-bundle-assets.sh` and `scripts/sim-common.sh`:
  `tests 4 / pass 0 / fail 4`, exit 1.
- `after-fix-staging.log` -- the same tests against the fixed scripts:
  `tests 4 / pass 4 / fail 0`, exit 0.

The failures are the two independent gaps:

1. `copy-bundle-assets.sh` copied `worker-entry.js`, `www/` and the image to
   `Bundle/worker/` but not `tool-worker-python.js`, so the installed app had
   no nested python Worker.
2. `sim_prepare_worker_assets` (shared by `sim.sh` and `scenarios.sh`) built
   the staging directory from a prebuilt bundle and dropped
   `tool-worker-python.js` before the copy script ran, so the same artifact was
   missing even when the build cache had it.

The fix makes both steps copy the artifact and makes both steps fail loud when
it is absent, instead of building an app that hangs on python commands.

The logs are the raw `node --test` output with the worktree and temporary
directory paths replaced by `<worktree>` and `<tmp>`.
