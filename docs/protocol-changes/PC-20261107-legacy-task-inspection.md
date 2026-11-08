# Freeze read-only legacy task inspection

```yaml
change: PC-20261107-legacy-task-inspection
contracts: [P07, P09, P18]
status: frozen
breaking: false
version_decision: No persisted or wire format change; concurrent journal initialization fails busy while a local inspection is active.
base: 1747309343746a5c4a571c1f743e2b45514e4cd0
contract_revision: spec/device/v1/legacy-task-inspection.md@sha256:8ae310bd779a74917b029a9b399314f8a8917cfac0dc31233af7c09b217480ab
```

## Trigger and delta

Protocol impact: P07; P09; P18. Legacy task files can remain after BLE task
grants are refused; the current fail-fast journal reader creates storage and
acquires a process record lock, so it cannot provide a non-mutating evidence
view. A historical UUID, key fingerprint or plaintext result cannot prove a
past identity or remote outcome. Freeze the limited local inspection described
in the owning document, not automatic recovery or a new task capability.

An inspector reserves process-wide exclusion against **all** task-journal
initializers and owners before opening candidates; journal initialization
fails busy rather than waiting while an inspection is active. Ownership
registration must cover initialization and lock release, including error and
cancellation paths. The short bookkeeping mutex must never span I/O. Files are
observed via anchored no-follow descriptors, bounded preview/enumeration and
explicit incomplete status; the budgets do not change stored-data validity.
The UI begins only on user action, exposes no task or outcome contents or raw paths,
and never starts an engine or task. Existing journal files, unknown members,
locks, identity preferences and old receipts are not changed or authenticated.

Shared fixture `spec/device/v1/golden/legacy-task-inspection.jsonl` is SHA-256
`fd66070537571fa8bc6c43855106676e048fa1aaf6c4fae633f78e9a44feaf42`;
its schema SHA-256 is
`07608610da2ad4c13dabc2dbefb5cf091fe09ed9eff309fab6dc956a7949b8b6`.
The shared escaped-path vectors and schema have SHA-256
`a8912a2d9a4aea417f5b75f59e4966dae2bdda3bbfdd839c5f9fbd5150c8f988` and
`d5cee16d4c636bcf41f5bf79440772167b6ee1c47ea65ab74b9bdcd6608cacf7`.
The claim vectors and schema have SHA-256
`c2b2bbd27628e3924766e726e62064b17d1f4ca81ce81bbf2378f1380483d57f` and
`f64452bf415b16054d2f7210b0dde1b2a1dcd05b756bbf32dab09373391d35be`.
The linked owner clauses `task-delegation.md` and UI `page-completeness.md`
are SHA-256 `84d30b93f6b20a5c8cc38c060bbedb8e19d0ed16b2ed5207d6e5dd3e5ee65822`
and `5814478abbf64f6e4d42d47d4ee606baed6bad31cfc6479e31af9c8c7af7819d`.

## Compatibility and roles

Old data → new inspector remains untouched, including malformed, oversized,
unknown and orphaned files; any unexamined data remains explicitly incomplete.
New app → old data does not migrate identity, grant tasks or claim delivery.
Old app/rollback ignores the in-memory inspector; concurrent old processes are
not coordinated and cannot yield a verified snapshot. No wire/version/record
field changes. An iOS app-container file is unavailable to Android; the new
local affordance is not evidence for Android feature parity or a reason to
relax P0. The broader cross-platform device capabilities remain unfinished.

The coordinator owns `spec/**` and this change record. The core implementer owns
`Sources/PhoneDSHDeviceTasks/DeviceTaskJournal.swift`, new inspection/gate
files in that module and scanner tests. A separate parser implementer owns
`Sources/PhoneDSHDeviceTasks/UniqueJSONKeys.swift` and a new dedicated parser
test file; the core implementer must not edit either. The UI implementer
owns `examples/probe-app/PhoneDSHProbe/BluetoothDevicesPage.swift`, any new
probe-only presentation files and their probe tests; it must use the frozen
core API and not start task management. No other agent edits these paths.
Review the combined head, including the cross-process/in-process limitations.

Acceptance: `swift test --filter PhoneDSHDeviceTasksTests`; the affected
probe/UI build and tests using an isolated simulator; and
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Use actual files and existing journal code rather than copied model-only
validators. Record all failures and skips. GAP-24, legacy identity recovery,
secure task-session implementation and physical-device acceptance remain open.

## Revision 2 — preserve raw JSON semantics without call-stack recursion

The first frozen revision was `legacy-task-inspection.md@sha256:5fe8797305fab7b6ea29fbc274e4179007a3d7a7a89e1cf92436e132ec629296`
at commit `ad822267fa98b2b51f119d053e61c220984f1a81`. A real scanner test
of a bounded, deeply nested input terminated the XCTest process with SIGBUS;
the crash report shows recursive `UniqueJSONKeys.value` frames. The implementer
stopped that part and requested a contract revision. Freeze replacement of the
existing recursive value walk with an explicit stack, retaining the existing
depth boundary and both entry points' different duplicate/NUL policies. The
scanner uses extracted scalar claims and must not hand the whole deep tree to
Foundation. This revision does not change stored or wire validity, widen a
schema, suppress a fixture or close GAP-23; a scanner unable to inspect deeper
records calls them `unparsed`, never corrupt, and preserves bytes.

Shared `golden/legacy-task-inspection-deep.jsonl` SHA-256 is
`b131d0a6944026c7ef96e0374be3158174a3654e06731b47c4b30e91437a463d`;
its schema SHA-256 is
`54943f3d4a9741eb4ba3ffc9ce0371d61d3f8e4e89c0f33a85d69c8d02b1d48a`.
The core implementer must run these through the real scanner and validator,
all earlier task and journal vectors, the C host suite and Python task tests.
The caller-visible format and old/new/rollback compatibility remain unchanged;
the pre-existing production journal subsequently calls `JSONDecoder` on the
whole record, so scanner safety alone does not establish journal safety for
deep inputs. Swift worker-stack and actual iOS evidence are separate from the
macOS crash and must be reported exactly.

## Revision 3 — constrain the root URL

At revision 2, independent testing of the in-progress scanner showed that a
root symlink followed by `/.` is followed despite `O_NOFOLLOW` on the path's
last component; a file URL with a remote authority was also silently treated
as a local path by Foundation. No implementation was merged. The owner changes
the not-yet-shipped public API to `inspect()` so it obtains the fixed journal
under the OS-provided Application Support ancestor; only an internal test
entry may inject another trusted root. Inspect the actual decoded filesystem
bytes and reject `.`/`..`, a nonempty host, any user/password/port or
query/fragment, and non-file inputs;
remove trailing separators before no-follow opening. Do not standardize away
`..`, and do not reject trusted OS-managed ancestor symlinks. This keeps the
storage format, identity and non-replay semantics unchanged.

Shared `golden/legacy-task-inspection-roots.jsonl` SHA-256 is
`ea1a170ac9fab40f2ffe71da0fd8b39c535b39b104bc611f3ac55b19a214eee0`;
its schema SHA-256 is
`f374bab200bd2beffa184b5df4db9db4b44e35da03250e03cafafd5f61912c33`.
Both implementers must update to the new API after this revision is committed.
The scanner must drive the root vectors through actual filesystem operations,
and the UI integration must verify the OS-derived default in an isolated
app container, not inspect the user's unrelated Application Support files.

## Implementation evidence

The frozen revision at `8b013fc2` is implemented as a bounded local inspection
and user-initiated probe presentation. It does not recover or authenticate old
identities, establish journal consistency, replay tasks, or enable BLE task
grants. The iterative parser retains the prior raw-key policies; the scanner
extracts only scalar claims. An independent review exercised the actual scanner
against root-symlink and URL-authority counterexamples and found no remaining
blocker in that scope.

* `swift test --filter PhoneDSHDeviceTasksTests` → PASS: 49 tests, zero
  failures or skips. The APFS invalid-UTF-8 filename case could not be created;
  the byte-escaping vectors passed, but that actual filesystem case is NOT_RUN.
* `swift test --filter UniqueJSONKeysIterativeTests` → PASS: three tests, all
  12 deep shared vectors. Independent differential checks against the old
  parser covered 18,062 inputs in each of three modes with zero differences.
* `swift build -c release --target PhoneDSHDeviceTasks` → PASS. Debug-only
  test hooks were absent from the inspected release objects.
* `bash firmware/tests/run.sh` → PASS with ASan/UBSan, using the pinned cJSON
  component temporarily; `python3 examples/lan-mcp-device/test_tasks.py` →
  PASS, seven tests.
* An isolated simulator `xcodebuild build-for-testing` and
  `xcodebuild test-without-building` using the real core and presentation
  sources → PASS, five tests, zero failures or skips, including manual
  Chinese/English language overrides and system-language fallback. The full
  `PhoneDSHSim` target also built for testing. The full hostless
  simulator suite separately failed to load `libswiftWebKit.dylib`; no tests
  ran there. These results do not establish physical-device acceptance.
* A uniquely identified, separately signed iPhone test app built and installed
  with synthetic journal data in its own container. Its XCTest runner lost
  its IDE connection; the test command timed out after 240 seconds, with zero
  tests executed: INCOMPLETE. Both the app and runner were uninstalled and
  their absence independently checked.
* `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
  → PASS / FAIL / PASS. P0 still reports eight stale or missing structures;
  no baseline or checker was weakened.

GAP-23, GAP-24, production secure-session and identity recovery, Android
capabilities and physical end-to-end device-task acceptance remain open.
