<!-- SPDX-License-Identifier: MIT -->
# iOS evidence-based Bot activity

Status: normative iOS-only refinement, 2026-11-14. Android adaptation is explicitly deferred
by the user. The existing shared activity-phrases/strings/value schemas remain unchanged for
compatibility; iOS uses `BotActivityEvidence` to normalize labels before displaying them.
No field is added to BotActivity, DSH events, persisted rows, or the Worker stream.

## Sources and labels

`BotActivityEvidence.action` permits only bash.description and Task.task_title/description as
an action description. Use the first speech-compatible allowed intent and the spoken-label rules below. Reject credential-shaped assignments/Bearer text, generic thinking fillers and obvious completion assertions: an intent label is not a completion receipt. Task
prompt and CreateTeammate.description retain their business meanings. Other description,
summary and label fields are ignored; use the tool kind for a short fallback, without a target suffix.
Unknown calls wait for a tool result without exposing their internal name. Missing bash
purpose says “执行当前操作”. Normalized empty activities use one stable phase label rather than
feeding the legacy synonym rotation pool. This does not expose raw reasoning or generate a
new model request. First public text must actually be observed before “正在回复”.

## Lifecycle

Order events by seq with stable arrival order on ties; determine the latest still-open turn.
An explicit old-turn end/result cannot terminate a new turn. Missing turn IDs retain existing
legacy compatibility, never overriding an explicit mismatched ID.

Track all unresolved calls, including hidden FishAction, to correlate results. Display the
newest unresolved visible call. Duplicated known call IDs do not reopen settled work. Results
with an ID close only that ID; without an ID they close only a single unambiguous outstanding
call (visible or hidden). Unknown IDs, invalid/conflicting ID fields and ambiguous missing IDs close nothing. Step start and
user steering do not cancel work. Turn end removes the activity; local stop retains existing
suppression and cancellation behavior. Reconstruction uses the current turn history.

After the last visible call returns, keep its operation kind as context, e.g. “已收到读取结果”
or “已收到查询结果”; use “这步遇到问题” for message.isError/error-object. A subsequent step keeps this context
until actual text or a new action arrives. Receiving a result does not assert business success.
If a tool remains unresolved, actual text streaming does not erase that in-flight action.
Approval/problem precedence remains in BotHeaderPresence. Reasoning-only records do not count
as public reply text. Unknown event timestamps remain 0 (no invented elapsed-time origin).

## Compatibility and validation

The existing JSON shape is unchanged; no transport or persistence migration is required.
Android continues its previous presentation rules until its separate adaptation. Shared
legacy phrase APIs remain available; the production iOS line calls the evidence policy.
`activity-evidence-vectors.json` is consumed by Swift tests running the real factory. Cases
cover encoded/object args, concurrent reverse completion, missing/unknown IDs, hidden calls,
steering, stream/step boundaries, failure, duplicate replay, old-turn isolation, and semantic
or sensitive-field misuse. Additional tests check stable labels and approval precedence.

## Spoken-label refinement

Activity detail is a short natural-language sentence suitable for future TTS (TTS delivery is
not implemented here). Prefer 8–14 Chinese characters, with a 16-character cap for Chinese intent
labels (at most 7 words / 48 characters for non-CJK labels); reject overlong labels rather than speaking a truncated ellipsis. Do not include file
names, paths, extensions, URLs, internal IDs, code, or technical separators in activity detail.
Use the operation kind as a truthful fallback when the intended purpose cannot be displayed.
Only approved semantic description fields can provide the purpose; the actual tool/result
lifecycle remains authoritative. Result labels say a result was received, not that the task was
verified successful. Generic fillers and completion assertions remain rejected.

Future speech should consume this stable detail, not UI animation frames or the UI-only elapsed
time suffix. Do not create extra model calls or status narration merely to keep speech active.
