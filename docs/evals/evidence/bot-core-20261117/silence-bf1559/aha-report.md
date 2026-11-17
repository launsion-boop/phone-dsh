# aha multi-turn evaluation report

- upstream: `real`
- repeat: 3
- generated: 2026-11-17T07:46:07.385181Z
- engine exit: 0
- overall: **PASS**
- reason: every selected scenario passed under the real-model precondition
- catalog sha256: `43d30c7003a891122ab742f194e7173bbf1c806391360d3fea3aded61a4c52c9`
- dimensions sha256: `740c2a77f91f1530162ce17c98713e0c55b0bb4701530539d31c6ff35924da5d`

| scenario | status | engine | hard | soft | provenance |
| --- | --- | --- | --- | --- | --- |
| AHA-SILENCE | PASS | PASS | pass | 1.00 | p0=pass, docs=0 |

## Dimensions

### AHA-SILENCE — PASS
- reason: all hard dimensions passed and soft score met the threshold
- [PASS] interruption (hard)
  - [ok] assertion[0] bot_event
  - [ok] assertion[1] bot_event
  - [ok] assertion[2] no_bot_event
- [PASS] restraint (soft)
  - [ok] assertion[3] memory_absent
  - [ok] assertion[4] no_bot_event
  - [ok] assertion[5] no_bot_event
- provenance p0: pass, planned extended fields: NOT_RUN (missing: review)

Mock upstream never yields a model PASS. `NOT_RUN` means the evidence or
prerequisite is missing; it is not a weaker pass.
