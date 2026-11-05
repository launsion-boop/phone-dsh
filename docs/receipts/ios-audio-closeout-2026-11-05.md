# iOS audio handoff closeout, 2026-11-05

This run verifies the audio ownership fix on top of PR33. Recording across
lock and keep-alive handoff pass. Starting a new recording after lock fails
on the tested device. PR31 and PR32 are closed without merging. PR33 is the
integration base.

## Revisions and scope

Base `515e3395a4b7c80a522bd4f12f76edd0b5c2a058`; audio implementation
`18fd20c3bc9d2a69dd43def600abe684f97e9489`. Contract revision `3a6eb665`,
`spec/platform/ios-audio-session.md` revision 2.

Protocol impact: P08; P09: none — app-local audio ownership changes without
trajectory or UI projection changes; P19: none — arguments, confirmation, result
and error envelopes remain unchanged. Worker, SDK, Rust, Kotlin, WAL, artifact
format and persisted settings are unchanged. All ProbeKit and app callers migrate
together in one bundle; old/new source API combinations are unsupported.

## What was actually wrong

On the unmodified PR33 base, a recording started at 03:28:30 UTC. Locking during
that recording caused keep-alive activation to fail at 03:28:34 with 560557684,
followed by park failure at 03:28:52 in a fresh test workspace.

The first ownership candidate preserved live recording across background and
foreground, but still reconfigured an already owned microphone profile. A
separate device trace showed playAndRecord with category options 13 before a
repeated setter in the background. The setter failed with 560557684 and left
options 0. The final change reuses the retained profile until zero owners.

The lease now grants an exclusive microphone token. A stale or repeated release
has no effect; idle composer cancellation releases no claim. Keep-alive start and
stop preserve a live microphone owner. Only the last owner deactivates the
session. A pure keep-alive run retains playback plus mixing.

## Corrected recording finding

The earlier near-empty recording result was contaminated by Device Hub screen
sharing. With sharing active, AAC, PCM and explicit-stop recorder variants all
had effectively no input. An engine-tap experiment produced full-length frames
containing only silence. With sharing stopped, the original unmodified recorder
produced 4.967619 seconds of valid audio for a five-second request, with audible
signal and a matching artifact SHA. No recording-engine replacement was kept.

This follows Attack the Premise: testing the shared environment disproved the
recording-replacement premise. Fix Root Causes keeps the production delta at
session ownership. Prove It Works checks decoded samples and event progression.
Sequence Verifiable Units keeps the retained-profile regression before its fix.

## Device and test method

Physical iPhone 18 Pro Max, iOS 27.0.1, USB charging, no Bluetooth dependency and
no debugger attached. The isolated `dev.phone-dsh.audiolock` bundle links the
native shell. Existing Worker assets are reused because no plugin source changed.
Fresh workspace roots and an ephemeral argument-domain override select fresh
test sessions; existing app data is retained.

The production voice entry stays hidden. The voice case uses a validation-only
ChatPage task to call the real ComposerVoiceInput and finish capture; diagnostic
logging records only nonempty status and character count. The installed validation
snapshot differs from production only in this driver and error logging in
ComposerVoiceInput. The lease, native record tool and keep-alive are production
code. Screen sharing is off while capturing. A capture-control failure delayed
the first final-round lock; its pre-lock recordings are not counted as locked
reacquisition evidence.

The upstream is a deterministic local SSE fixture driving real native tool calls.
This validates the agent/Worker/native path, not model intelligence. For every
recording, copy the immutable artifact from the test container, compare its SHA
with the tool receipt, then inspect decoded sample count using afinfo and ffprobe.

## Results

| Case | Revision and observed result |
| --- | --- |
| Foreground three-second recording | Ownership candidate, PASS, 2.970703 valid seconds; SHA matches. |
| Foreground five-second recording | Ownership candidate, PASS, 4.967619 valid seconds; SHA matches. |
| Recording, background, foreground while still recording | Ownership candidate, PASS; start 03:40:00, background 03:40:23, foreground 03:40:39, native result 03:40:41; 39.960091 valid seconds, SHA matches. The final guard changes only later retained-profile reacquisition. |
| Recording followed by background streaming | Ownership candidate, PASS; heartbeats progress for 82 seconds before return to foreground. |
| Recording then lock, microphone release back to keep-alive | Ownership candidate, PASS; start 03:44:34, lock/background 03:44:53; new test artifact has 59.952472 valid seconds and matching stored SHA. The bash tool became a background job at 60 seconds; direct job_output receipt was not collected for this case. |
| Earlier seven-minute locked stream | Ownership candidate, PASS; 410-second heartbeat, native event progression, turn ends locked at 03:51:50. Installation followed before idle parking was fully observed, so that run does not prove park completion. |
| Voice input with actual human speech | Final audio code, PASS; nonempty six-character device transcript at 04:04:30, capture and recognition inactive at 04:04:42. Transcript content is not saved in evidence. |
| Final retained-profile locked reacquisition | FAIL on final audio code. First recording starts at 06:17:15 UTC, then the device locks and keep-alive starts at 06:17:24. The first recording finishes at 06:17:45 with 29.952290 valid seconds, 1,320,896 decoded frames and a matching artifact SHA. Two new five-second requests start after lock at 06:17:51 and 06:17:56. Both reach `AVAudioRecorder.record(forDuration:)`, which returns false. Both return `microphone/unavailable` without an artifact. |
| Locked task completion after two failed recorder starts | PASS. The fixture emits all 73 ticks. The final heartbeat at 388 seconds reports 100 events and live audio. The turn completes at 06:23:57 UTC, releases keep-alive audio and logs Host parked. Device lock state still requires a passcode. Native conversation metrics report error 12 during parking, but the explicit completion and park events are present. |
| Final voice-input then locked streaming completion and idle park | Final audio code, PASS; recording active before lock/background at 04:05:49, 360-second heartbeat with native event progression, locked turn completion and Host parked at 04:11:53. The preceding two recordings occurred before lock and do not validate locked reacquisition. |

## Automated verification

| Command | Result |
| --- | --- |
| `xcodebuild test -project /tmp/phone-audio-unit/AudioOwnershipTests.xcodeproj -scheme AudioOwnershipTests -destination "platform=iOS Simulator,id=A0D88FC3-A32A-4FB8-BC9E-FB376248B0EB" -derivedDataPath /tmp/phone-audio-unit/Derived -resultBundlePath /tmp/phone-audio-unit/reacquire-final.xcresult` | PASS, 13 tests. |
| Same suite before retained-profile fix | FAIL as intended, two assertions in the new reacquisition regression; configuration counts 2/3 instead of 1/2. |
| `swift test --filter ProbeScenePhaseWiringTests` | PASS, five tests after migration. |
| `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | phone-spec PASS; phone-cross-tree PASS; phone-p0-conformance FAIL on existing ChatPage color-provenance line drift. |
| `bash scripts/ci/check.sh --only phone-no-dsh-patch,phone-hygiene,phone-license,phone-gate-contracts` | no-dsh-patch PASS; hygiene and license FAIL on unchanged Android findings; gate-contracts FAIL because its production hygiene selftest sees those same findings. |
| `python3 spec/tools/registry_check.py` | PASS, 22 contracts. |
| `python3 spec/platform/tools/platform_check.py` | PASS, 26 entries, zero failures. |
| `python3 scripts/ci/protocol_impact.py --base 515e3395 --body-file <declaration>` | PASS, P08 and P09 covered. |
| `git diff --check` | PASS. |
| Independent DSH review | APPROVE full caller ownership and retained-profile guard; static review only. Codex owns actual build and device verification. |

The simulator project compiles the repository's actual lease, scene forwarder,
envelope and capability sources into ProbeKit and runs the existing lifecycle
test file. It does not replace the implementation with a test copy. Build and
XCTest logs, native receipts and sanitized metadata are retained in local evidence.

## Limits and handoff

The dedicated locked reacquisition run establishes that retaining the
playAndRecord profile is insufficient to start a new recording after the prior
capture stops. The tool reaches the recorder start guard after obtaining the
lease. This is consistent with the background recording activation restriction
[described by Apple DTS](https://developer.apple.com/forums/thread/816408). The
recorder returns a Boolean, so this trace does not identify its internal OS error.
PR35 remains on hold if locked recording initiation is required for acceptance.
Media-service reset, interruption recovery, process
termination, power loss, other iOS versions, speech accuracy and real-model
end-to-end behavior are not certified by this run. Raw microphone files and
transcript content stay local and are not included in shared evidence.

No SDK or WAL workaround is introduced. The fresh-base park failure is tracked as part of the audio transition repro.
The final run records idle park after all native recording calls finish. The unrelated baseline gate failures remain
outside this change.
