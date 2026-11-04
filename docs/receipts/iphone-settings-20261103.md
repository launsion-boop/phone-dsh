# Independent iPhone settings fixes — 2026-11-03

Historical receipt for `edb6c419`. Its Creator BLOCKED state is superseded by
the [Creator follow-up](iphone-creator-20261103.md); the original results below
are retained as the record of that earlier revision.

Base: `fe33f75f46e970c051668027d85e9748b8f591ce` (public main).
Reported device baseline: `f36ad8d3084c1264c3588f45d94ae5bd506c5c42`.
Branch: `codex/iphone-settings-fix-20261103`. PR14 is not updated by this work.

Protocol impact: corrections to consumers of the existing DSH Remote API;
no endpoint, wire format, on-disk format or database migration changes.
Generated iOS page contracts/source anchors are refreshed. Android sources and
the page-divergence baseline/allowlist are unchanged.

## Owning behavior reproduced locally

These responses were obtained from the real packed Worker in this work, not
reconstructed from the user's lifecycle logs:

- `settings/update`, namespace `permission`: `settings/rejected`, with
  `Configuration for "permission" is overridden by a home patch or command-line overlay`.
- `agentPresets/list` with `{action: "list"}`: `gateway/arguments-invalid`,
  rejecting the unexpected `action` argument.
- `settings/update`, namespace `agent-preset-registry`: `settings/rejected`,
  also identifying the home patch/command-line overlay.

The shipped phone profile declares these defaults in its home patch, above the
editable profile layer. The provider-wide `settings.writable` flag does not
authorize writing through that layer. The native default-permission page now
shows the current value and an explicit read-only startup-policy explanation;
it does not claim that a new permission value was saved. Existing sessions are
not changed. The same startup ownership is made explicit for the default agent
preset. Changing this policy to allow persistent user overrides is not part of
this patch.

`DSHRemoteError` now supplies the server code and message to
`localizedDescription`, and retains optional server `details` for unary and mux
errors. It no longer loses the diagnostic behind the Foundation `error 1` text.

## Native behavior

- Presets use official `agentPresets/list` arguments `{}` and the direct
  `presets` result. YAML uses `agentPresets/read` with `agentPreset`, and reads
  direct `content`. The YAML viewer supports scrolling and text selection.
- “Use preset” passes the requested identity into `session/create`, without a
  prompt. Successful creation closes the actual settings-sheet binding and the
  compact session drawer. Failure retains the page and reports the error.
- Creator mode remains **BLOCKED**: the shipped `cordis` roster reports missing
  `cordisInspect` and `pluginManager` services. The entry is disabled with the
  real reason. It does not create a standard session, auto-send a task, or claim
  to have generated a preset file. Real preset generation is **NOT_RUN**.
- Settings sheets observe the saved appearance. The drawer no longer injects
  a light color scheme into those sheets. Dark appearance was inspected after
  reopening settings and after a simulator cold launch.
- The send arrow uses its existing state-dependent label: send, queue next
  turn, or supplement the current task. Busy VoiceOver interaction is
  **NOT_RUN**; no queue execution logic is changed here.
- The production About page is available in Release. The Debug preview
  expression simplification was already present in the base; Debug compilation
  was verified rather than attributed to this patch.

## Latency boundary

The reported 3m41s recall and 6m16s tool turn ultimately completed, and the recall
was correct according to the device report. They are not classified here as
permanent stalls, context loss, or evidence of insufficient phone compute.
The supplied lifecycle logs do not isolate model/network/tool/client time.

New `latency client-observed` records in `Documents/chat-status.log` cover prompt
RPC start/acceptance/failure, turn start/end, first reasoning/assistant output,
tool-call/result receipt, and stream resynchronization. Event source time,
sequence and client uptime distinguish observations from replay. These records
omit prompt text, attachments, model responses and keys. RPC acceptance is not
execution; the records are not upstream model timings. Reproducing the long
turns and identifying their cause with the new logs is **NOT_RUN**.

## Verification

- `swift test --filter 'DSHRemoteErrorTests|DSHRemoteHarnessResumeTests'`:
  **PASS**, 6 tests.
- `phone-sdk`: **PASS**, 1452 tests, 5 skipped, 0 failures.
- `phone-plugins` with the configured pinned DSH checkout: **PASS**, 2362 passed,
  20 skipped, 0 failures. The first invocation without that environment failed;
  the corrected invocation reran the complete plugin stage.
- `phone-image`, `phone-gate-contracts`, `phone-hygiene`, `phone-license`,
  `phone-no-dsh-patch`: **PASS**. `phone-spec`, `phone-p0-conformance`,
  `phone-cross-tree`, `phone-bundle-fresh`: **PASS**.
- Clean `copy-bundle-assets.sh --force` without a Web dist: **PASS**, rebuilt
  Worker/image using the verified pin. A regression also exercises this build
  path; the previous unbound `WEB_VERSION` is fixed.
- `scripts/ci/smoke.sh`, rebuilt assets, real macOS WKWebView and scripted model:
  **PASS**, 3 tests. This is not an iPhone or real-provider result.
- Native XCTest, iPhone 17 Pro / iOS 26.5 Simulator, no preview launch flag,
  model key, auto-prompt or substituted RPC: dark settings immediate/reopen/cold
  launch **PASS**; startup-lock display, actual roster/YAML, healthy preset
  selection and full settings dismissal **PASS**. Non-default `ptc` was also
  read back from the native menu's actual session projection without a prompt;
  its AX role is a disabled button, not static text. The flow passed after the
  native regression caught and corrected the one-level-only dismissal.
- iOS Simulator Debug build: **PASS**. Unsigned generic iOS Release build:
  **PASS**. These builds did not enable the optional Rust shell FFI; physical
  signing and native-command/CSV E2E are not inferred from compilation.

Physical iPhone 18 Pro Max / iOS 27.0.1, data/key-preserving installation,
real-provider chat, actual CSV import/output, random-code model recall,
HealthKit/HomeKit and latency reproduction are **NOT_RUN** on this branch.
The native simulator tests do not replace the user's device acceptance.
No physical-device data, keychain, model key, original attachment bundle or
private application logs were uploaded or modified by this work.
