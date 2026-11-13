# Persist the partial assistant stream when a turn is interrupted

Status: **upstream proposal note; not a patch and not applied**. phone-dsh keeps
its pinned DSH checkout unmodified (AGENTS.md §6, CONTRIBUTING "Zero DSH source
patches"; the pin is DSH `0.2.2-rc.1`, commit
`66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db` per `plugins/dsh-pin.json`). This note
records the durable-session gap and a proposed upstream fix; it does not assert
that the current DSH pin already behaves this way.

## Problem

When the App or its WebContent is killed while the model is streaming, the
reply that was already visible disappears from the session. DSH persists
assistant text only when a step settles (`assistant/message`). An unfinished
Assistant stream is deliberately transient in the session-checkpoint policy:
the host WAL contains the acked events, but there is no durable assistant
message to project. On the next open DSH repairs the session by appending
`turn/end{kind:'interrupted'}`; the streamed text is absent.

The phone host's WAL is not the problem: acknowledged writes survive process
death. The missing record is the assistant attempt itself. A user sees the
session "roll back" to the prompt even though the model had produced a partial
answer, and a client has no durable fact to explain why.

## Evidence in this repository

- `examples/probe-app/PhoneDSHProbe/ChatModel.swift` receives live
  `.reasoningDelta` / `.assistantDelta`, accumulates text in
  `streamAccumulator` and paints streaming `ChatItem` rows. Those rows exist
  only in memory until `assistant/message` arrives.
- `ProbeKit/Transcript/NativeTranscriptProjector.swift` projects
  `assistant/message` blocks. It has no source for a partial attempt.
- `ProbeKit/Transcript/SessionHistoryReader.swift` records
  `turn/end.reason.kind` (`turnFacts.endReasons`), including the `interrupted`
  repair. It therefore proves the turn ended abnormally but cannot recover the
  text.
- `docs/receipts/ios-session-audit/01-data-path.md` independently notes that
  live stream text is lost mid-stream and waits for `assistant/message`, and
  that `assistant/message.interrupted` is not projected by the native client.
- The DSH session-checkpoint policy keeps unfinished Assistant streams
  transient. This note cites that policy as the authority; it does not restate
  its internals as a new contract.

## Proposed DSH change

Persist a partial assistant attempt as a durable, explicitly unfinished event:

```jsonc
// assistant/attempt (proposed; event name and schema are DSH's decision)
{
  "turn": 7,
  "step": 3,
  "stream": "...",
  "interrupted": true,          // never a settled assistant/message
  "content": [
    { "type": "reasoning", "text": "..." },
    { "type": "text", "text": "..." }
  ],
  "truncated": false
}
```

Write it on two triggers:

1. **Bounded timer while streaming.** At most once per second per active
   attempt, coalescing the same content blocks the live client already shows.
   The write is ordered before the next stream event and never blocks model
   decoding.
2. **On the repair path.** Before DSH appends
   `turn/end{kind:'interrupted'}` for an abandoned attempt, snapshot the last
   accumulated text (even if the timer has not fired). This covers a kill that
   happens inside the one-second window.

Suggested semantics for maintainers to settle:

- `assistant/attempt` is **not** a settled message. It must not count as a
  completed step, must not enter model context, and must not be replayed as an
  `assistant/message`.
- When the step later settles, `assistant/message` replaces the attempt's
  content for that turn/step. A client must not render both.
- Bound the record (for example the same per-row byte cap the client uses) and
  set `truncated: true` when only the tail survives.
- Project the record as a visible, clearly labelled partial row. The client
  must not send it back to the model or treat it as a completed answer.
- On a session that is opened after the kill, the attempt is already in the
  durable log, so every client sees the same text instead of each platform
  inventing a local cache.

Alternative minimal change, if a new durable event is too large for the
checkpoint policy: at the repair point only, synthesize an
`assistant/attempt{interrupted:true}` from the in-memory live stream before
`turn/end`. This loses at most the text the process could not read after a
hard kill, but it gives the durable session a record for every orderly
`interrupted` repair. The timer variant is preferred because a `SIGKILL` of
WebContent does not run the repair in the dead process.

## Why phoneDSH keeps a display-only local draft meanwhile

phoneDSH may not patch DSH, so this branch adds a local, per-`(backend,
session)` draft file beside the transcript snapshot:

- It stores only the current streaming assistant/reasoning rows and is written
  on a serial utility queue, throttled to once per second with an immediate
  flush when the App goes inactive/background, on a turn boundary and on a
  durable settle.
- It is capped at 512 KiB per session (the tail is kept and marked truncated),
  excluded from backup, and deleted when the session is archived/erased or its
  snapshot is evicted.
- On a history load it paints rows only when history shows the turn ended
  non-normally (`interrupted` / `failed` / `cancelled`) or did not end while the
  engine reports no running turn, and only when history has no settled
  assistant/reasoning text at or after the draft position. Rows carry a visible
  "已中断" note, are never sent to the model, are excluded from the transcript
  snapshot, and are consumed after one paint so a second reload cannot
  duplicate them.
- It cannot make the session durable, cannot survive an uninstall, and does not
  change what other clients or the model see. It is a stopgap until upstream
  persists the attempt.

## Tests and risk in this branch

The local behavior is covered by `PhoneDSHSimTests/NativeStreamDraftTests.swift`:
throttled writes, background flush, normal-settle deletion, settled-message
precedence, one-paint-then-clear reload semantics, non-normal turn filtering,
512 KiB tail truncation, snapshot exclusion, scope isolation, and snapshot
eviction / local-data erase cleanup.

Risks: the local draft is display-only and can be at most one throttle window
behind a hard kill; it is not a substitute for a durable DSH record. A future
`assistant/attempt` projection should replace the draft source, and the draft
file/format can then be removed without a DSH contract change.

## Not verified

This proposal was not applied to the pinned DSH checkout and no DSH test ran.
It does not claim device, WebContent-kill or model end-to-end coverage; the
phone-side behavior is simulator-tested only.
