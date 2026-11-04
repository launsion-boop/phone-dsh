# L85 — chat context dies when the Worker session is replaced (P0)

Baseline `0b732a7f`, Xiaomi M2102K1C / Android 14 / arm64 / real DeepSeek.
Status: **fixed and measured**, on the device lane with the scripted upstream
(`android/tools/acceptance/`, explicitly **not** a model).

## Symptom (reported)

New chat → "Reply with PR14CHATOK and the result of 17 times 19" → 323. Import a
CSV through the system picker, dedupe it, then ask "what exact multiplication did
I request at the start?" → `UNKNOWN`. The transcript still showed the earlier
question and 323.

## Root cause: two defects, in this order

### 1. `session/prompt` identities repeated inside one Session (the trigger)

`DshTurnClient.prompt` minted `pdsh-prompt-<n>` from a **per-client** counter.
The chat builds a new `DshTurnClient` for every send, so every send was
`pdsh-prompt-1`. The Worker deduplicates a prompt by that id against the
Session's durable `user/message` sources:

```js
// @deepseek-ai/dsh-api-session-controller/lib/index.js:927,1128
if (hasPromptRequest(agent, request.requestId)) return { accepted: true };
```

So the second send was answered `{accepted:true}` and **never delivered**: no
turn started, the follow stream had only the history snapshot, and after the
20 s first-event deadline the App reported `no_turn_started`.

### 2. `no_turn_started` was misread as "the stored session is stale"

`ChatTurnRunner` treated *any* failure of the stored session as proof the
session was gone and opened a new one. The session was alive and resumable; the
new one simply had no history, so the model answered `UNKNOWN` — while the App's
transcript kept the old messages. That is the worst state: no context, no notice.

## What the Worker actually provides

* **No history/context parameter.** `SessionCreateRequest` has only
  `workspaceId`, `cwd`, `sessionId`, `agentPreset`
  (`dsh-api-session-controller/lib/types/types.d.ts:284`). `sessionId` is a
  blank-session reuse hint: `claim()` refuses a named session that has started a
  turn and creates a *new minted* id instead. **Route (a) does not exist.**
* **Sessions are persisted.** The phone profile mounts
  `session-persistence-journaled` at `$DSH_HOME/sessions` (plaintext JSONL,
  `plugins/profile/phone.worker.cordis.patch.yml:616`), and `/dsh/home/**` is
  host-persisted and repacked into every boot (`wal.md` §8, `BootOverlay`), so a
  reloaded page mounts the same log.
* **`session/prompt` resumes a cold session.** `resolveAgent` → `resolve` →
  `agents.resume`, which reads the persisted prefix and seeds the new Agent with
  it. The only session-level failure is `session/not-found`.
* **The official Web client mints `randomUUID()` per submission**
  (`dsh-api-session-controller/lib/client.js:2310`) — the same rule the host
  client now follows.

Therefore the correct fix is **(c): keep the Worker session id and let the Worker
resume it**, not (b) text replay.

## Fix

1. `DshTurnClient.prompt` mints a fresh `requestId` per submission
   (`newPromptRequestId()`); a caller may pass one only to retry the same send.
   `PromptIdentityTest` (2 tests).
2. `ChatTurnRunner.run` tries the stored session **first**, and opens a new one
   **only** on the Worker's own `session/not-found` (and only when no event was
   observed for that attempt). `workerSessionGone()` is the one predicate;
   `ChatTurnRunnerTest` pins that `no_turn_started`/`stream_error`/`writer-held`
   never discard the session.
3. `ProbeEngineViewModel.sendChat` passes the chat record's `workerSessionId`
   (persisted) instead of the process-live id, so a cold start resumes.
4. Fail-loud: on `session/not-found` the App calls `onContextLost` →
   `recordContextLost` writes a durable `status` row (`contextLostNode`) **and**
   the banner: 「上一段上下文已丢失：…」. `ChatContextLostTest` (3 tests) proves
   the row and banner render.

## Evidence — real Worker runtime (Node harness, two processes)

`plugins/tests/session-resume.test.ts` boots the packed image twice:

* boot 1: one turn, then a second `session/prompt` with the **same**
  `requestId` → `accepted=true`, 0 turns, 0 model requests (the swallow), and
  the persisted `/dsh/home` + `/dsh/workspace` are drained;
* boot 2: a **new process** mounts that tree as its boot overlay, sends the
  recall question with a fresh `requestId`; the model request carries the first
  prompt and the scripted model answers `CONTEXT-OK 323`.

PASS (14 s). Only model output is scripted: persistence, overlay, resume and
prompt idempotency are the pinned runtime's own.

## Evidence — device (AVD, API 35, scripted upstream)

`bash android/tools/acceptance/run-chat-context-flow.sh` — 6/6 PASS:

| scenario | result |
| --- | --- |
| S1 SAF import CSV → process → recall | PASS `CONTEXT-OK 323` |
| S2 picker cancelled (BACK) → recall | PASS `CONTEXT-OK 323` |
| S3 background 8 s → recall | PASS `CONTEXT-OK 323` |
| S4 share sheet cancelled → recall | PASS `CONTEXT-OK 323` |
| S5 cold start (force-stop, reopen) → recall | PASS `CONTEXT-OK 323` |
| S6 session log deleted + Worker rebuilt | PASS 「上一段上下文已丢失」 row + `APP_CHAT_CONTEXT_LOST` |

The upstream is `fixtures/scripted-acceptance-upstream.py` (a script): its recall
lane answers `CONTEXT-OK 323` only when the **request transcript** carries the
secret, so a replaced session answers `UNKNOWN`. The transcript arrives from the
Worker's resumed session, not from the App re-sending history.

## Can the Worker rebuild during SAF be avoided?

Not in this lane. `WebViewEngine.configure` already sets
`setRendererPriorityPolicy(RENDERER_PRIORITY_BOUND, false)`
(`android/engine/WebViewEngine.kt:655`): the renderer is not waived when the
WebView is invisible, but `BOUND` ties its priority to the App's — which drops
while the App is backgrounded for the system picker. The stronger setting is
`RENDERER_PRIORITY_IMPORTANT` (still only a hint; the OS may reclaim under
memory pressure). That file is outside L85's writable set (`android/engine/**`),
so it is handed off as an open question. With resume fixed, a rebuild is no
longer lossy: it costs a page reload, not the conversation.

## Gates

* `android ./gradlew :app:testDebugUnitTest :app:assembleDebug` — PASS
* `scripts/ci/check.sh --only phone-android-tests` — PASS (2040 JVM tests)
* `scripts/ci/check.sh --only phone-p0-conformance` — PASS (73 tests)
* `plugins npm run typecheck` — PASS
* `plugins npm test` — PASS (2408 tests, 0 fail, 20 skipped)
