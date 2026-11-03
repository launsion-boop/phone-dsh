<!-- SPDX-License-Identifier: MIT -->

# Personal Agent Prompt and Interaction Integration — 2026-11-04

## Prompt assembly

The stable English `PersonalAgentCorePrompt.text` is the first system section. It contains only the Core System Prompt from the handoff, not the complete handoff, runtime template, or integration contract. English instructions do not force English replies; the current user language takes precedence, with `zh-Hans` as the safe default.

`PersonalAgentContextProvider` appends one JSON-encoded `runtime_context` object. Values are built per turn, after the stable core. The current request, task state, retrieved memory, and connector content remain data rather than policy or authorization. Core policy is never truncated. Core, runtime context, protected task data, tool schemas, and messages all participate in the measured UTF-8 byte budget.

| Field | Runtime source | Missing-value behavior |
| --- | --- | --- |
| `assistant_name` | Shared `personalAgent.displayName` profile | `小肥鱼` only when unset |
| `user_name` | Onboarding/user-approved `displayName` Memory | `null`; never inferred |
| `preferred_language` | Current user text, then preference | `zh-Hans`; current language overrides |
| `now` | Host clock, RFC 3339 with offset | Assembly fails if unavailable |
| `user_timezone` | Validated device IANA timezone | `null` if invalid; timezone-dependent work must resolve it |
| `delegated_scopes` | Active host-issued `WorkMandate` records | Empty array; expired scopes are removed |
| `capabilities` | Actual `ConnectorToolDescriptor` handlers and model-name codec | Empty array; no invented handlers |
| `interaction_state` | Pending questions, unresolved operations, scoped suggestion history | Verified empty only when stores are empty |
| `suggestion_policy` | Host policy | 4 options, 7-day dismissal, 30-day decline, stop after 2 declines, no multi-select |

## Registered capability bindings

| Operation | Registered handler and state authority | Result contract |
| --- | --- | --- |
| `rename_assistant` | `LocalCapabilityToolInvoker` → `PersonalAgentProfileStore` | Shared settings/Header/onboarding value, read-after-write, restart persistence, explicit failure on mismatch |
| `memory_set_profile`, `memory_set_preference`, `memory_log`, `memory_delete` | `LocalCapabilityToolInvoker` → `MemoryStore` | Principal/account/source/revision checked; confirmed revised/unchanged/forgotten result |
| `memory_open_loop` | `LocalCapabilityToolInvoker` → `FollowUpStore` | Real waiting-user/waiting-external/done/cancelled/expired state; no duplicate task ledger |
| `memory_get_suggestion_history`, `memory_record_suggestion` | `SuggestionStoreHistoryAdapter` → `SuggestionStore` | Scoped canonical history with independent shown/selected/dismissed/declined/superseded/expired outcomes |
| `suggest_card` | `NativeSuggestionGenerator` structured tool output → `PersonalAgentModel` and native card | `none`, `next_steps`, or `clarification`; never approval; no fixed fallback |
| `schedule_list/create/update/delete` | `DSHScheduleAdapter` → `DSHManagementModel` and existing DSH scheduler | Actual catalog state, dedupe, timezone validation, cancellation and next-run status; `after(seconds)` creation only in this adapter |
| Approval | Existing `WorkMandate`, `DefaultWriteGate`, grant versions, operation ledger | Separate host workflow; no model-authorized approval tool and no unconditional allow |

The DSH schedule adapter is injected by `PhoneDSHProbeApp`. Hostless tests use only capabilities available in that environment. Background execution remains bounded by the running DSH host and iOS scheduling; exact-time execution is not promised.

## Interaction lifecycle

Cards contain host-owned schema version, card/conversation/turn/principal/account IDs, creation/expiry, suppression keys, kind, question, options, and outcome. Model output cannot override those fields or register callbacks, tools, targets, or credentials.

- `next_steps`: 1–4 distinct valid options, `dismiss_on_move_on=true`.
- `clarification`: blocking question with 0–4 options and `dismiss_on_move_on=false`; zero options requires custom text. It uses `PendingQuestion`, not a competing optional-card state.
- `none`: exactly no card. Invalid, duplicate, stale, failed, or unavailable generation produces no card.
- Approval is independent and suppresses optional suggestions.

`selected`, `dismissed`, `declined`, `superseded`, and `expired` are separate events. Selection persists before sending the option's `user_request` through normal ingress and the write gate. It is not dismissal and cannot authorize an external write. A double click or retry uses a host selection event ID and cannot create duplicate turns. Late results cannot revive a dismissed, superseded, expired, account-switched, or conversation-switched card.

Dismissal suppresses the canonical action/target across turns for 7 days. Explicit declines use 30 days and stop unsolicited repeats after two. Moving on supersedes optional cards without counting as a refusal. New direct user requests are handled normally. Legacy records keep their old same-turn suppression and an `unknown` outcome rather than inventing intent.

## Text and trust boundaries

`PersonalAgentTextPolicy` preserves user-requested fenced code and does not replace an empty answer with a fabricated completion phrase. Technical thinking, raw tool protocols, and internal routing remain out of the minimal timeline. The main runtime and the optional suggestion channel use the same actual capability and interaction state but the small suggestion request does not duplicate the full core or every tool schema.

## Measured prompt size

- Core System Prompt: **13,786 UTF-8 bytes**, byte-for-byte equal to the supplied `personal-agent-system-prompt.en.md`.
- Default runtime context envelope: **506 UTF-8 bytes**.
- Core plus default runtime context: **14,292 UTF-8 bytes**.

These are measured bytes, not provider token counts. Runtime identity, capabilities, history, task context, tool schemas, and messages change the final request size. `MainAssembledContext` exposes core/runtime/tool/message/total bytes and budget separately.

## Verification boundary

Focused deterministic tests and simulator UI verify plumbing, state transitions, and presentation. They do not establish actual model compliance or external account behavior. Real model, API key, GitHub PAT, Gmail OAuth, external DSH scheduler, and physical-device acceptance remain `NOT_RUN` unless separately configured and executed.
