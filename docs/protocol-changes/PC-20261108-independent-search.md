# Independent Search/Fetch API on Android

```yaml
change: PC-20261108-independent-search
contracts: [P05, P09, P16, P18, P20]
status: frozen
breaking: false
version_decision: No version change. The gateway schema, /v1/http envelope, Worker variable names and provider IDs are unchanged; the cookie route and the Android settings document are additive.
base: 0e9ad261
contract_revision: spec/v1/golden/gateway/independent-search/cases.json@sha256:688277843b29634171165224c5bb0344846a9d8abf80be71e4e3c1bdece060ae
```

## 1. Trigger

- Trigger: a hosted Search/Fetch service (for example base `https://pdsh.tonoai.cn/v1/web`
  with its own Bearer key; the provider appends `/search` and `/fetch`) cannot be
  configured on Android.
- Current: Android reports the web-search page as read-only and only mounts the official
  follow-model grant. The shared bridge routes a cookie-authenticated Worker's web tools
  through the host only for `https://api.deepseek.com/v1/tools`. With any other base a
  cookie Worker would send directly with the placeholder key, bypassing host credential
  injection and egress policy.
- Expected: Android stores an independent mode, base and key, publishes the existing
  Search/Fetch provider variables for a canonical base, and grants exactly the two
  operations with the independent key. The bridge carries them over `/v1/http` with the
  launch bearer.
- Coordinator and contract owner, Worker implementer, Android implementer and
  reviewer: one agent in this task, producing each role's output.
- Owning clause: [gateway-independent-search.md](../../spec/v1/gateway-independent-search.md),
  linked from [gateway-official-web.md](../../spec/v1/gateway-official-web.md). Shared
  fixture: [independent-search/cases.json](../../spec/v1/golden/gateway/independent-search/cases.json).
- Ends: TS `plugins/llm-bridge/src/install.ts` (consumer of the Worker variables, cookie
  route producer); Kotlin `android/net` gateway (route consumer); Kotlin `android/app`
  launch (variable producer), settings store and facts; `android/lib` page route (P09).
  iOS and Harmony are not changed (§3).

## 2. Delta

| Item | Before → after |
| --- | --- |
| Base URL | none on Android → §1 canonical base, `https` only, DNS host, no port, userinfo, query, fragment or percent-encoding, safe segments, not ending in `search`/`fetch`, trailing `/` removed |
| Operations | official only → also exact `POST <base>/search` and `POST <base>/fetch` |
| Auth | model key for official → independent key from its own account, resolved per request, caller credentials stripped, Bearer injected last; never the model key |
| Redirect / log | unchanged rules applied: all redirects refused, exchange sensitive, never logged |
| Worker env | official values only → the same four entries with the canonical base and placeholder `phone-host-injects-search-key`, only when mode, base and key are valid |
| Cookie route | official base only → also a canonical independent base; missing route or launch bearer fails instead of a direct send |
| Precedence | follow-model only → independent mode replaces the official grant; an incomplete or unreadable independent setup leaves both tools off |
| Android settings | none → private `{version:1, mode, baseUrl}` document, key under account `search.deepseek.api`; a changed base deletes the key first; a key needs a stored base |
| P09 page | read-only → mode, address, key, clear-key and remove are wired to host actions whose text never prints the key |
| P20 | image rebuilt from the same pin so the Android APK carries the new bridge; formats unchanged |

Self-check: no second envelope, field alias or error code. The Worker variables and
provider IDs already exist (iOS publishes them). The bridge change only adds a route for
values the host already validates. The settings document is new private data with a
version field. Unknown versions, modes and members are unreadable.

## 3. Compatibility

| Producer → consumer | Behavior |
| --- | --- |
| Old Worker → new Android host | The old bridge does not route a non-official base over `/v1/http`. Those requests go directly with the placeholder and the service rejects them (401). No key leaks. Rebuild the Worker image with the APK. |
| New Worker → old Android host | Old hosts never publish an independent base, so the new route is never selected. |
| New → new | Both operations go through the host with the independent key. |
| iOS (channel token) | Unchanged. Every request already uses `/v1/http` with the channel bearer, and the iOS credential router owns the independent key. |
| Harmony | Unchanged. It does not publish an independent base. Not started. |
| Persisted data → new / rollback | No document means follow-model mode, so existing installs keep the official behavior. A rollback ignores the document and the separate key account, and the older page stays read-only. |

## 4. Ownership and acceptance

- The contract owner owns `spec/**`, this record and `spec/tools/cross_check.py` (golden reader).
- The Worker implementer owns `plugins/llm-bridge/src/install.ts` and
  `plugins/tests/llm-install.test.ts`. Acceptance:
  `cd plugins && node scripts/run-tests.mjs tests/llm-install.test.ts`.
- The Android implementer owns `android/net/.../gateway/IndependentSearchWebTools.kt`, the `android/app` settings, launch, facts and
  shell files, `android/lib` `PdshNavFacts.kt` and `PdshNavHost.kt`, plus their tests.
  Acceptance: `:net:testDebugUnitTest :lib:testDebugUnitTest :app:testDebugUnitTest
  :app:assembleDebug` with the rebuilt bundle.
- The TS bridge test and the Kotlin gateway test both read the shared fixture.
- Not covered: physical-phone behavior, the live service and model E2E.

## 5. Revisions

| Revision | Change |
| --- | --- |
| cases.json@sha256:68827784 | Frozen clause, shared bases and request cases. |
