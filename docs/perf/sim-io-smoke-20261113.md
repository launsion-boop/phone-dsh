Protocol impact: none — verification report only
<!-- SPDX-License-Identifier: MIT -->

# Simulator end-to-end smoke: `turn-io` from a real probe-app build — 2026-11-13

- Base commit: `631e26e06cc5c2ff6334ef8def0ce69226907a9d` (`origin/main`, PR #147 merge)
- Branch: `test/sim-io-smoke`
- Verdict: **PROVEN (iOS Simulator only)** — two real turns of the probe app
  appended `turn-io` lines with nonzero counters to the existing
  `Documents/boot-timings.log`.
- This report adds only this file. No source, spec, test, script or CI file was
  modified.

> **This is simulator evidence, not device evidence.** It must not be used as a
> `spec/v1/budgets.md` §7 device baseline. See §5 for what it cannot prove.

## 1. Result in one paragraph

Using the probe app built from this checkout, installed and launched on an
iPhone 17 simulator (iOS 26.5), the app booted its real Worker
(`worker-boot=1171ms hello=1171ms running=1174ms` in the same log) and completed
two ordinary user turns. Each settled turn wrote one `turn-io` record into
`Documents/boot-timings.log`; the first reported `fsync_calls=10
bytes_written=90789`, the second `fsync_calls=8 bytes_written=60653`. Both
values are nonzero, so the counter window is actually wired to the app's turn
lifecycle in a real app build, not only in the unit test that asserts the
same line.

The exact `CODE_SIGNING_ALLOWED=NO` build requested by the task succeeded and
was installed, but that unsigned artifact cannot read the app Keychain
(`provider seed failed: keychain(-34018)`), so it cannot hold a model API key
and cannot start a model turn. The turn evidence therefore comes from a second
build of the same sources/project with Xcode's normal simulator signing; this is
a build-setting difference only, and it is recorded as a limitation in §5.2.
The model upstream was a local scripted SSE server, not a real model; see §2.4.

## 2. What was run

### 2.1 Workspace and build

```bash
# in the worktree /Users/leilangsheng/Desktop/Phone DSH public/dsh-work/sim-io
cp -R "/Users/leilangsheng/Desktop/TonoTeam/phone-dsh/examples/probe-app/Bundle/worker" \
  examples/probe-app/Bundle/worker          # gitignored staging, deleted after the run
cd examples/probe-app
xcodegen generate                            # exit 0
xcodebuild build -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/simio-dd CODE_SIGNING_ALLOWED=NO > /tmp/simio-build.log 2>&1
```

Result of the exact requested build (`/tmp/simio-build.log`):

```text
** BUILD SUCCEEDED **
real 274.01
```

There were dependency-scan warnings (for example `'PhoneDSHShell' is missing a
dependency on 'PhoneDSHAgentCore'`), but no `error:` lines.

The launch-time Keychain seed failed with that unsigned artifact
(`/tmp/simio-evidence/chat-status.log`):

```text
2026-11-12T16:28:47Z provider seed failed: keychain(-34018)
```

`-34018` is `errSecMissingEntitlement`. The app's own `Config/PhoneDSHProbe.entitlements`
declares the Keychain access group precisely so a signed build can read its own
items; an unsigned simulator artifact does not get it. The same project and
sources were therefore rebuilt with signing enabled (no `CODE_SIGNING_ALLOWED=NO`):

```bash
xcodebuild build -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/simio-dd \
  > /tmp/simio-build-signed.log 2>&1
# ** BUILD SUCCEEDED **
```

With that build the seed succeeded:

```text
2026-11-12T16:32:21Z provider seed: deepseek, model=deepseek-flash, key=present
```

### 2.2 Simulator, install and launch

- Simulator: **iPhone 17**, UDID `6B341EA5-718F-43E3-AE4A-14358D592C9B`
- Runtime: **iOS 26.5 (26.5 - 23F77)** `com.apple.CoreSimulator.SimRuntime.iOS-26-5`
- Xcode: **26.5 (17F42)**; host macOS 26.3.1 on Apple M5 Pro (arm64)
- Bundle id: `dev.phone-dsh.probe`
- App container for the evidence run:
  `/Users/leilangsheng/Library/Developer/CoreSimulator/Devices/6B341EA5-718F-43E3-AE4A-14358D592C9B/data/Containers/Data/Application/480877BD-14F2-4460-B9FB-AB7B1DD75BF3`

```bash
xcrun simctl boot 6B341EA5-718F-43E3-AE4A-14358D592C9B
xcrun simctl install 6B341EA5-718F-43E3-AE4A-14358D592C9B \
  /tmp/simio-dd/Build/Products/Debug-iphonesimulator/PhoneDSHProbe.app
```

The turn was started through the existing Debug-only unattended hook in
`examples/probe-app/PhoneDSHProbe/ChatModel.swift`
(`PDSH_CHAT_AUTOSTART` / `PDSH_CHAT_AUTOPROMPT`), with a `simctl launch`
environment. This is the same hook the device UI tests use; no app code was
changed.

### 2.3 Two real turns

The first prompt was sent at `16:34:26Z` and the second at `16:34:58Z`; each
opened a fresh host boot and a fresh counter window (different `boot=` ids, same
session). The app's own status log records the real lifecycle
(`/tmp/simio-evidence/chat-status.log`):

```text
2026-11-12T16:34:26Z Session resumed: session-9cefa41c-3ebe-4a07-a0b4-d0d6b45fac82; egress hosts=14
2026-11-12T16:34:26Z Autostart prompt delivered=true started=true
2026-11-12T16:34:26Z latency client-observed phase=turn-start turn=1 seq=56 ...
2026-11-12T16:34:26Z latency client-observed phase=turn-end turn=1 seq=176 ...
2026-11-12T16:34:26Z Turn ended: completed
...
2026-11-12T16:34:58Z Autostart prompt delivered=true started=true
2026-11-12T16:34:58Z latency client-observed phase=turn-start turn=2 seq=208 ...
2026-11-12T16:34:58Z latency client-observed phase=turn-end turn=2 seq=264 ...
2026-11-12T16:34:58Z Turn ended: completed
```

### 2.4 Model upstream: scripted, local

No real model credential is available in this environment. The app therefore
talked to a temporary local SSE server on `127.0.0.1` that answers
`POST /v1/messages` with one final text message (`PDSH_SIM_IO_OK`). Its event
shape follows the repository's scripted upstream,
`Sources/PhoneDSHHarness/MockModelUpstream.swift` (`message_start`,
`content_block_*`, `message_delta`, `message_stop`); it was a minimal
out-of-process copy because `simctl launch` needs a listener that outlives the
XCTest runner. It is **not** a real model and its file is not part of this
repository. The app-side Worker boot, turn lifecycle, WAL/journal writes and
counters are real; only the model replies are scripted.

The mock was reached three times with the injected key present
(`/tmp/simio-evidence/mock-requests.jsonl`, fields trimmed):

```text
{"path": "/v1/messages", "api_key_present": true, "body_bytes": 773,   ...}
{"path": "/v1/messages", "api_key_present": true, "body_bytes": 38938, ...}
{"path": "/v1/messages", "api_key_present": true, "body_bytes": 39107, ...}
```

### 2.5 A UI-test route that did not work (not used as evidence)

Before launching through `simctl`, the existing scripted UI test was tried:

```bash
xcodebuild test -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHDeviceUI \
  -destination 'platform=iOS Simulator,id=6B341EA5-718F-43E3-AE4A-14358D592C9B' \
  -derivedDataPath /tmp/simio-dd CODE_SIGNING_ALLOWED=NO \
  -only-testing:PhoneDSHDeviceUITests/PhoneDSHDeviceUITests/testScriptedSessionTaskFromComposer
```

It failed before sending a prompt:

```text
PhoneDSHDeviceUITests.swift:405: error: -[PhoneDSHDeviceUITests.PhoneDSHDeviceUITests testScriptedSessionTaskFromComposer] : XCTAssertTrue failed
```

Line 405 waits for `app.buttons["新建会话"]`; the current drawer shows a button
labelled **`新会话`** (`examples/probe-app/PhoneDSHProbe/HomeDrawer.swift:202`).
The app itself booted during that attempt (`boot ... running=2773ms`), but no
turn ran, so that run is not evidence. This stale accessibility label is a
separate test-maintenance issue, not part of this task.

## 3. Raw `turn-io` evidence

Complete `Documents/boot-timings.log` from the evidence run (copy:
`/tmp/simio-evidence/boot-timings.log`):

```text
boot 2026-11-12T16:28:52Z ok recovery=7ms machine+journal=28ms overlay=42ms loopback=43ms webview=201ms engine-navigation=1943ms engine-ready=2554ms worker-boot=2770ms hello=2771ms running=2773ms wall=2774ms
boot 2026-11-12T16:32:24Z ok recovery=9ms machine+journal=18ms overlay=21ms loopback=22ms webview=155ms engine-navigation=719ms engine-ready=1287ms worker-boot=1454ms hello=1454ms running=1455ms wall=1456ms
boot 2026-11-12T16:34:26Z ok recovery=13ms machine+journal=17ms overlay=21ms loopback=22ms webview=65ms engine-navigation=608ms engine-ready=1113ms worker-boot=1185ms hello=1185ms running=1186ms wall=1188ms
turn-io 2026-11-12T16:34:26Z boot=73fb27e8b215d74e8cef00ce6c5ae490 session=session-9cefa41c-3ebe-4a07-a0b4-d0d6b45fac82 turn=1 outcome=completed fsync_calls=10 bytes_written=90789
boot 2026-11-12T16:34:58Z ok recovery=11ms machine+journal=17ms overlay=23ms loopback=24ms webview=64ms engine-navigation=594ms engine-ready=1101ms worker-boot=1171ms hello=1171ms running=1174ms wall=1175ms
turn-io 2026-11-12T16:34:58Z boot=5b8b374a76834cd46be6648fdd5fcce5 session=session-9cefa41c-3ebe-4a07-a0b4-d0d6b45fac82 turn=2 outcome=completed fsync_calls=8 bytes_written=60653
```

`grep -c 'turn-io'` on that file returns **2**. Line numbers are 4 and 6.

| Turn | `boot=` | `outcome` | `fsync_calls` | `bytes_written` |
|---|---|---|---|---|
| 1 | `73fb27e8b215d74e8cef00ce6c5ae490` | `completed` | **10** | **90,789** |
| 2 | `5b8b374a76834cd46be6648fdd5fcce5` | `completed` | **8** | **60,653** |

The two values differ because they are separate process boots and separate turn
windows: the line is emitted from the settled sample, not a cumulative process
total. The boot lines in the same file show the real Worker boot
(`worker-boot` / `hello` / `running`) for each app start.

## 4. What this establishes

1. In a real simulator app build of this checkout, a completed user turn goes
   through `PhoneDSHHost.harness()` and the
   `PhoneDSHTurnPersistenceIOSupervisor`, the window is settled on the terminal
   event, and the sink appends one `turn-io` line to the pre-existing
   `boot-timings.log` (`Sources/PhoneDSH/PhoneDSHHost.swift:114`,
   `Sources/PhoneDSH/PhoneDSHTurnPersistenceIO.swift:245`).
2. The two counters are not always zero in the app: turn 1 reported 10 fsyncs
   and 90,789 bytes; turn 2 reported 8 fsyncs and 60,653 bytes.
3. The pipeline is not limited to the unit test: it works across two real app
   launches and two real DSH turns on the same session.

It does **not** establish a device baseline, a performance target, or a
statistically meaningful median. Two turns on one simulator are evidence of
wiring, not of cost.

## 5. What this does not prove

### 5.1 Not a device

- No physical iPhone: no jetsam, memory pressure, thermal throttling, Low Power
  Mode, background suspension, OS cache eviction/reclaim, or storage pressure.
- No real APFS allocation: the counters come from `write()`/`fsync` call sites
  in `PhoneDSHLog`; they are not physical block usage, write amplification, or
  NAND latency. The simulator's I/O latency is the host's, not a phone's.
- No power measurement and no background/idle window.
- The app status log reports `batt=na/charging=na` on the simulator.

### 5.2 Build and signing

- The exact requested build used `CODE_SIGNING_ALLOWED=NO`; it built, but that
  artifact cannot access the app Keychain (`-34018`) and therefore could not
  start a model turn. The evidence run used a signing-enabled simulator build
  of the same sources and project.
- The build is Debug (the seed/autostart hooks are `#if DEBUG`). Release
  behaviour is not covered here.
- `PDSH_WITH_SHELL` was not set; the linked xz-shell command library was not
  present. The turns in this run were text-only and did not execute shell
  tools, so shell-path writes are outside this evidence.

### 5.3 Model and scope

- The model reply was served by a local scripted SSE upstream, not a real
  DeepSeek endpoint. Real network latency, provider errors, retries and
  cancellation were not exercised.
- Only the stores owned by `PhoneDSHLog` are counted (WAL segments, journal,
  materialized copy, blob store, overlay, manifest). Steps, exec ledger and
  response log live in other modules and are **not** part of these two numbers,
  so the `budgets.md` §7 row is not filled by this run.
- No crash, power loss, torn write, park/stop teardown, background resume or
  epoch-close-inside-turn scenario was tested. The nonzero fsyncs are simply
  what the two turns performed; their individual call sites were not
  instrumented per store in this smoke.
- One device model, one runtime and two turns: no median, min/max or
  cross-device comparison.

### 5.4 Worker asset provenance

`examples/probe-app/Bundle/worker` is gitignored and was staged from another
checkout to satisfy the `CpResource` step, as the task allowed. That Worker
image is old (files dated 2026-11-01/02) and its pin/version was not audited
against `plugins/dsh-pin.json`. It booted and completed turns here, but this run
does not prove that this image is protocol-identical to the pinned Worker. The
staged copy was deleted after the run.

## 6. Reproduction notes

- Build and both launches use `-derivedDataPath /tmp/simio-dd`; the app product
  is `/tmp/simio-dd/Build/Products/Debug-iphonesimulator/PhoneDSHProbe.app`.
- The evidence was pulled from the simulator data container; the app itself was
  installed with `simctl install` and launched with `simctl launch` plus
  `SIMCTL_CHILD_PDSH_*` environment variables.
- The model upstream was a temporary `/tmp` server, not part of the repository.
  For a repository-owned rerun, the existing
  `PhoneDSHDeviceUITests/testScriptedSessionTaskFromComposer` path is the
  intended fixture, but it currently stops at the stale `新建会话` label
  described in §2.5.
- Raw evidence retained outside the repository:
  `/tmp/simio-evidence/boot-timings.log`,
  `/tmp/simio-evidence/chat-status.log`,
  `/tmp/simio-evidence/mock-requests.jsonl`,
  `/tmp/simio-build.log`, `/tmp/simio-build-signed.log`.

## 7. Conclusion

**PROVEN for the iOS Simulator app-build pipeline**: the probe app's real turn
lifecycle produces `turn-io` lines in `boot-timings.log`, and both counters are
nonzero across two turns in two app launches. This is not a device or performance-baseline
claim; jetsam, power, system reclaim, APFS physical allocation and real device
I/O latency remain unverified.
