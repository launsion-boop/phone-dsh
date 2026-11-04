<!-- SPDX-License-Identifier: MIT -->

# PR #29 full-audit remediation ledger

Audit HEAD: `8c753c8c69c04bb5db87ddd57137505d4b5d93a9`. Remediation commit: `25d6e966`. The branch also integrates current `origin/main` `451429acc0f3ebe3bc244666f23a3acba3bdf12f`; the final merge/integration SHA is reported in PR #29.

| Finding | Status | Implementation and focused evidence |
| --- | --- | --- |
| F1 card/negative authorization | Fixed | Typed `SuggestionSelection` carries visible label/card version/original Mandate. `MainIngress.ingestSelection` cannot expand authority; `authoritativeClauses` rejects negative, quoted and analytical text. `PA_MandateTests`, isolated negated-Mandate gate repro. |
| F2 read-only local writes | Fixed | `MandateAction` scopes for profile/Memory/FollowUp/history/schedule, enforced in `LocalCapabilityToolInvoker`. Model-written Memory is `candidate + modelInference`. `PA_LocalCapabilityToolInvokerTests`, isolated read-only rename repro. |
| F3 scheduler session/rule/retry | Fixed | Requested session ID, typed `afterSeconds`, stable candidate reconciliation and dedupe. Isolated adapter harness: requested session, `.after(60)`, one create, other principal rejected. |
| F4 Gmail grant/identity | Fixed | Real write-grant toggles, OAuth `compose` intersection, `GmailAccountBindingStore` maps the local principal to the selected provider account. Existing scope-gate tests. |
| F5 breaker/unknown reconciliation | Fixed | GitHub/Gmail writers record operation/failure/unknown; GitHub issue create/comment and Gmail send/draft create/update reconcilers preserve unknown on ambiguity. Connector write/reconcile tests. |
| F6 semantic cooldown | Fixed | Canonical keys derive from actions and structured targets, not model option IDs. Lifecycle tests verify semantic deduplication. |
| F7 clarification lifecycle | Fixed | Clarification suspends the original turn before completion; original answer/Mandate settle before selected follow-up. Model tests assert both turns complete and close remains interrupted without replay. |
| F8 notification/FollowUp route | Fixed | `UNUserNotificationCenterDelegate` handles foreground and cold-start responses; Chat clears its navigation stack and opens the scoped FollowUp UUID detail. |
| F9 duplicate deep-link crash | Fixed | Duplicate query names use first-value uniquing rather than a trapping dictionary initializer. `PA_DeepLinkTests`. |
| F10 DSH Gmail discovery | Fixed | Exact host capabilities project `gmail.search`, `gmail.message.get`, `gmail.thread.get`; writes remain absent. Worker capability test and typecheck. |
| F11 persistence/supersede | Fixed | Corrupt/future state preserves bytes, reports unhealthy and blocks reads/writes; failed supersede blocks ordinary sends. Lifecycle corruption tests and model recovery behavior. |
| F12 newMail fan-out | Fixed | One incremental result is shared by every scoped newMail FollowUp per coordinator pass. Two-owner records receive the same batch; another principal is excluded. |
| F13 Memory/language/timezone | Fixed | Context includes kind/scope/origin/observedAt/validFrom/expiresAt/revision. Explicit Memory preferences override native language/device timezone; suggestion language uses native preference. Integration/context tests. |
| F14 onboarding contract | Fixed | Extractor emits `第 N 步，共 2 步` plus `第 {step} 步，共 2 步`; consumer passes. 134 extractor/checker tests pass. |
| FollowUp/schedule scope | Fixed | Immutable FollowUp owner fields and scoped store/coordinator/notification paths; DSH schedule owner mapping and bound identity. Cross-principal negative tests. |
| Composer source/dark mode | Fixed | Composer no longer shows source text; evidence remains at message bubble bottom. Forced-light drawer override removed; HomeSpec/UIKit surfaces use dynamic light/dark tokens. Static source check only; no physical-device visual claim. |

## Verification actually run

- Merged `PhoneDSHSim` build: PASS.
- Focused simulator suite: **85 tests, 0 failures** (`TEST SUCCEEDED`). This covers the classes named above, not a real model or account.
- Worker `node scripts/run-tests.mjs worker-entry/src/capability-manifest.test.ts`: **19/19 PASS**; `npm run typecheck`: PASS.
- `python3 -m unittest spec/ui/v1/tools/test_extract_ios_pages.py spec/ui/v1/tools/test_page_structure_check.py`: **134/134 PASS**.
- Focused consumers for onboarding, Personal Agent Chat, App Dock and Home Drawer: PASS.
- Negated Mandate, read-only local write and scheduler isolated harnesses: PASS.
- `ui_check.py`: PASS, including light/dark contrast pairs and 132 source anchors. `phone-spec`, `phone-no-dsh-patch`, and `protocol_impact.py` (P09/P16/P18): PASS.
- `phone-cross-tree`: FAIL on pre-existing P08 schema changes outside this task. `phone-hygiene` / `phone-license`: FAIL on existing Android files outside this task. These are not relabeled as passes.
- Full `plugins npm test`: attempted but not green due unrelated existing tests/environment requirements (including `PDSH_DSH_CHECKOUT`); it is not reported as PASS.
- Independent current `origin/main` page consumer also has pre-existing stale contracts/divergences. Unrelated Android/page differences are not counted as Personal Agent validation failures or fixed by enlarging the baseline.

## Not run / boundaries

`NOT_RUN`: real model response, real GitHub account, real Gmail OAuth/account, external DSH scheduler, physical-device UI/dark-mode visual acceptance, and background scheduler delivery. No mock, scripted registration, historical result or simulator result is presented as those acceptances.
