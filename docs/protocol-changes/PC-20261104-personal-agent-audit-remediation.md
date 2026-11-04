<!-- SPDX-License-Identifier: MIT -->

# Personal Agent audit remediation contract change

## 0. Summary

```yaml
change: PC-20261104-personal-agent-audit-remediation
contracts: [P09, P18]
status: implemented
breaking: true
version_decision: Existing records remain readable; newly introduced local Mandate actions and account bindings are not rollback-compatible. Suggestion schema remains v1 with optional fields, while corrupt or future disk schema is rejected without writes. Worker Gmail rows are optional and projected only by exact host capabilities.
base: 451429acc0f3ebe3bc244666f23a3acba3bdf12f
contract_revision: personal-agent-contracts@25d6e966
```

Protocol impact: P09; P18

## 1. Scope and authority

- Coordinator/contract owner and reviewer-integrator: the PR #29 integrator.
- P09 authority: `spec/ui/v1/README.md`, its page contracts and the real iOS view source. Onboarding interpolated titles now have rendered `N` text plus a template; Dock/Drawer contracts retain every action with current source anchors. Appearance tokens support both light and dark modes.
- P18 authority: `plugins/worker-entry/src/capabilities.ts`. Gmail read tools appear only when their exact `phone-tool:<name>` host capabilities are declared; DSH receives no Gmail write projection. Ubuntu projection from current `main` remains intact.
- Personal Agent code contracts: `Contracts.swift`, `SuggestionContract.swift`, `FollowUpStore.swift`, `MainContext.swift`, connector grants and their real consumers. Local write actions are explicit: profile, memory, FollowUp, suggestion history and schedule scopes are separate from connector writes.
- No DSH source, SDK `Sources/**` protocol implementation, P01/P02 wire/WAL, or remote workflow is changed by this remediation.

## 2. Delta

| Area | Before → after |
| --- | --- |
| Authorization | Card hidden text re-minted authority → typed selection carrying visible label, card version and original Mandate; actions/evidence/targets can only be retained or reduced. Explicit negative, quoted and analytical text stays read-only. |
| Local capabilities | Mandate existence/read effect → per-action scope checks plus principal/account/expiry checks. Model-written Memory uses `modelInference`, not `userExplicit`. |
| Scheduling | Current DSH session substitution and `after` decoded as `at` → requested session, typed `afterSeconds`, owner-scoped catalog/mutation, read-back reconciliation before any retry. |
| Gmail | Read-only UI grant and principal/email string equality → OAuth scope/product-grant intersection and explicit local-principal/provider-account binding; five-second undo retained. |
| Writer recovery | Unmaintained breaker → real operation/failure/unknown updates and reconciliation for GitHub issue creation/comment and Gmail send/draft create/update; ambiguous results are not replayed. |
| Lifecycle | ID/conversation cooldown, post-completion clarification, generic FollowUp route → action/target cooldown, original-turn suspension/settlement, notification deep link to scoped detail. |
| Persistence | Corrupt state treated as empty and supersede errors ignored → original bytes preserved, unhealthy state blocks reads/writes and ordinary sends. FollowUp gains optional immutable owner scope. |
| Context/UI | Memory text-only projection and text-derived language → typed kind/scope/origin/time metadata and real language/timezone preferences. Composer source text is removed; evidence stays on its message bubble. |

## 3. Compatibility and release

| Producer → consumer | Behavior |
| --- | --- |
| old → new | Legacy suggestion cards and FollowUp records decode with absent optional owner/Mandate fields. Scoped production queries do not claim legacy unowned records. Old Worker images do not advertise Gmail reads. |
| new → old | Old app code cannot interpret newly introduced local Mandate actions or account-binding keys and must not be used to roll back those writes. Older Workers simply omit the new optional Gmail rows. |
| new → new | Host descriptor projection and native bridge use identical Gmail read names; writes still require grant + Mandate + gate. New UI contracts are regenerated from final source. |
| persisted old data → new / rollback | Old data is preserved. Corrupt/future suggestion state is never overwritten. New local-action Mandates and new owner/account mappings are not rollback-compatible. |

Release order is native host first, then Worker assets. No remote workflow is restored. Physical-device, real-model, real GitHub/Gmail account and external scheduler acceptance are not implied by this change.

## 4. Verification record

- `python3 -m unittest spec/ui/v1/tools/test_extract_ios_pages.py spec/ui/v1/tools/test_page_structure_check.py` → PASS, 134 tests.
- `python3 spec/ui/v1/tools/extract_ios_pages.py --root .` → PASS, 49 extracted pages; hand-written Dock/Drawer contracts checked separately.
- Current `origin/main` (`451429acc0f3ebe3bc244666f23a3acba3bdf12f`) independently fails pre-existing page-contract staleness and Android divergences; those unrelated failures are not relabeled as Personal Agent passes.
- Personal Agent focused simulator tests, merged build, Worker typecheck/tests and final protocol checks are recorded in the PR evidence after execution. Real model, external accounts, external scheduler and physical device remain `NOT_RUN` unless separately run.

## 5. Revision record

| Revision | Reason | Affected ends |
| --- | --- | --- |
| `25d6e966` | Close PR #29 F1–F14 security, persistence and lifecycle findings | Personal Agent model/runtime/stores, GitHub/Gmail bridges, iOS UI |
| merged `451429ac` | Preserve Ubuntu while adding host-projected Gmail reads; regenerate affected page contracts and fix iOS-only checker summary | Worker TypeScript, P09 consumer, iOS pages |
