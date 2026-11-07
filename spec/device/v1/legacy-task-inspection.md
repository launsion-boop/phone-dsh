# Legacy device-task inspection

Status: frozen; implementation and user-interface verification pending.
This is a local, read-only observation of the existing task journal, not a
task profile, authentication mechanism or evidence that a remote operation
occurred. It covers the mixed BLE/LAN `Application Support/device-task-journal`
directory, including the `ble-ops` subdirectory. The user explicitly starts
inspection from the default iOS probe's Bluetooth page; entering the page
alone does not inspect records, scan Bluetooth, start an engine or use a
network. Android has no access to an iOS app container; no Android device
capability or parity is claimed by this initial iOS-only inspection.

## Safety and concurrency

Inspection MUST NOT instantiate the journal, create directories or locks,
open `.lock`, write or delete any record, mutate preferences or keys, invoke
the Worker, device inbox or task engine, replay or report a task, or infer a
binding between a legacy UUID and a public key. A file's fields are untrusted
local claims, not proof of identity, provenance, execution or delivery.
In particular a terminal value is only a value observed locally, and a
missing intent does not prove that a request was never sent.

Because closing an unrelated hard link to a POSIX record-lock inode can release
the process's lock, the inspector and **all** `DeviceTaskJournal` initializers,
owners and destructors MUST share process-wide admission. An initializer
reserves before any directory or lock operation and stays registered through
success or failure; an owner stays registered through unlocking and closing.
Inspection reserves only when no initializer or owner exists; another scanner
or new initializer returns busy without opening a candidate. Release the
inspection reservation only after all its descriptors and worker activity have
finished, including cancellation and errors. The state mutex is held only for
short bookkeeping, never across I/O, callbacks or suspension. The existing
manager can retain a journal after intake stops; the UI must report busy and
must not silently stop it to inspect.

This gate covers the repository's task journals only. It does not coordinate
unrelated same-process record locks, uncooperative writers, another process or
a malicious actor able to modify app-private storage. The directory is assumed
application-private and not concurrently modified by an uncooperative actor;
outside that assumption, even file identity checks cannot prove safety. All
results, including an apparently successful scan, MUST say consistency and
completeness are unverified. GAP-24 remains open.

## iOS module interface

`PhoneDSHDeviceTasks` exposes the no-argument asynchronous, cancellable
`DeviceTaskLegacyInspector.inspect()` returning `DeviceTaskLegacyInspection`.
It obtains the trusted Application Support URL from the OS without creating it,
then appends the fixed `device-task-journal` component. Arbitrary caller URLs
are not exposed through the public API; an internal test entry may inject a
trusted ancestor and target directory to exercise the same real implementation.
If the OS does not return an Application Support URL, return `incomplete` with
`rootUnreadable` and do not create a directory.
The result has `status`
(`busy` or `incomplete`), an array of entries, a `cancelled` flag, and zero or
more reasons: `rootMissing`, `rootUnreadable`, `rootUnsupported`, `entryBudget`,
`byteBudget`, `ioError`, or `cancelled`. Each entry has a unique reversible
escaped relative `id`/`label`, a `kind`, and optional untrusted local claims
(`deviceID`, `taskID`, `phase`, `outcomeKind`). Kinds are `observed`,
`unparsed`, `unreadable`, `symlink`, `nonRegular`, and `unexamined`.
`observed` means only that bounded bytes were read and recognized as JSON; it
does not declare a valid task, stable bytes, trusted identity or outcome.
`unparsed` includes JSON the inspector cannot establish as parseable and does
not declare corruption. Claims may be supplied only when the relevant original
JSON members are unambiguous and can be parsed without losing duplicate-key
evidence; if a relevant object has duplicate claim-bearing members, all claims
for that entry are absent. Each claim must be a string of at most
256 original UTF-8 bytes and is escaped as below; longer, NUL-containing or
wrong-typed values are omitted rather than truncated or treated as trusted.
Task text, outcome content, raw file bytes and
absolute paths are never exposed. Results are `Sendable`; the core has no UI, Bluetooth, network
or Worker dependency. An inspector that is cancelled or hits a budget returns
incomplete with the observations it actually obtained; no detached worker may
outlive its reservation. Internal synchronization, tests and error reporting
must not require a new durable schema or network field.

The public result and its nested enums/entry/claims are `Sendable` and
`Equatable`: `DeviceTaskLegacyInspection.Status` (`busy`, `incomplete`),
`Reason` (the cases listed above), `Entry.Kind` (the cases listed above), and
`Entry.Claims` with optional `String` properties `deviceID`, `taskID`, `phase`,
and `outcomeKind`. `Entry` is `Identifiable` with `String` `id` and `label`,
`kind`, and optional `claims`. `status`, `[Entry]` `entries`, `Bool` `cancelled`
and `[Reason]` `reasons` are read-only result properties; reasons do not
repeat. For a parent record, claims correspond respectively to the root's
`device_id`, `task.id`, `phase`, and `outcome.kind`. For a `ble-ops` intent,
the `deviceID` and `taskID` claims come from the root's `device_id` and
`task_id`, and the other claims are absent. None is a proven fact. The public function returns a result rather than throwing, so busy,
cancelled, unavailable and partially observed cases remain distinguishable.

## Observation and privacy

Use descriptor-relative, close-on-exec, no-follow, nonblocking operations; do not follow a
symbolic link or read a FIFO, socket or other non-regular entry as a file.
Enumerate only the anchored root and `ble-ops` directories; never recurse into
other directories. The system-provided Application Support ancestor is trusted
and may include OS-managed symlinks; final journal and `ble-ops` components
must not be symlinks. Reject visibly hard-linked candidates rather than opening
them; this alone is not a substitute for the process-wide gate. Individually
list inaccessible, unknown, ambiguous and malformed entries, including intents
that may be orphaned, without claiming orphan classification or rewriting or
discarding the others. A missing directory is `incomplete`, not proof that no
history exists. Root and child file replacement, read failure, cancellation,
unknown filename bytes and a changed inode are incomplete observations, never
successful recovery.

Before opening the journal, inspect the actual absolute filesystem
representation, after URL decoding and before any path normalization. Reject
non-file URLs, a nonempty host (including `localhost`), any non-nil user,
password, port, query or fragment (including empty user/query/fragment), and
any `.` or `..` component. Remove trailing separators without resolving
path components, then apply `O_NOFOLLOW` to the actual final component; an
empty or root-only target is unsupported. This ensures a final symlink followed
by `/`, `/.` or encoded `.` cannot be followed. System-provided trusted
ancestors may still contain OS-managed symlinks; this rule does not authorize
caller-controlled ancestors. Shared `golden/legacy-task-inspection-roots.jsonl`
exercises the real scanner and OS-provided-directory integration. Do not use
lexical standardization of `..` as a substitute for rejecting it.

The inspector may preview at most 65,536 bytes per regular file and 4,194,304
bytes total per scan and may enumerate at most 16,385 non-dot entries. These
are **observation budgets**, not new journal-format limits; a skipped or
truncated file is `unexamined`, not corrupt, and its bytes remain untouched.
An exactly 65,536-byte file is observed only if the same open descriptor and
actual reads establish that it was not truncated by the budget; concurrent
in-place changes can still make the whole observation inconsistent. Directory
enumeration uses an independently opened description, not a duplicated fd
sharing another stream's cursor; `fdopendir` owns its supplied descriptor.
Cancellation is checked during iteration and reading. Raw filenames are used
for descriptor-relative lookup and escaped reversibly for display; invalid
UTF-8, bidirectional controls and path-like bytes must not be rendered as
unescaped trusted text. For each relative component, preserve ASCII letters,
digits, `.`, `_`, and `-`, and encode every other byte as `%HH` with uppercase
hex; join encoded components with `/`. Empty, `.`, `..`, NUL or slash-bearing
components are invalid and never path lookups. Encode claim values by the
same byte escaping rule, without treating `/` as a separator. Shared
`golden/legacy-task-inspection-paths.jsonl` fixes valid and invalid examples.
Avoid leaking absolute paths, contents or identifiers
to logs, analytics, the model or the network.

The interface initially shows escaped filenames, file type, bounded inspection
status and, when present, the explicitly unverified local claims above using
literal text rendering. Claims must wrap or clearly indicate any visual
truncation; they must not silently appear complete when clipped. It
does not display task text, outcome contents or other raw file contents. It
clearly says "local observation, consistency unverified; device
identity and remote outcome unknown" and offers retry after a busy or failed
scan. A later revision may add explicit sensitive-content viewing or export;
the current revision does not claim a recovery/export mechanism. UI changes
must not suppress existing P09 parity checks or relax their baselines.

`golden/legacy-task-inspection.jsonl` and its schema describe shared positive
and negative cases. `golden/legacy-task-inspection-claims.jsonl` fixes the
claim mapping and rejects ambiguous examples; source fields omitted from the
claim object do not imply anything about the underlying bytes. Tests must drive the real scanner and journal gate against
actual temporary files, including deterministic init/scan races, a lock inode
hard-linked or renamed into a candidate, no-follow symlink/FIFO cases, mixed
and malformed evidence, budget exhaustion and cancellation. Compare all
original bytes before and after; check no task/Worker/network calls occur.
Schema validation alone is not runtime evidence.

## Deep inputs and parser safety

An actual bounded inspection input crashed the existing recursive raw JSON
validator. The owning Swift validator must use an explicit stack rather than
call-stack recursion while preserving its existing token, Unicode, number,
duplicate-key and NUL behavior in both `check` and `rawRootMembers` modes.
In particular, `check` rejects duplicate names at every object depth whereas
the parent-member mode enforces uniqueness only for the specified root names
and preserves its existing policy for unknown members. Existing record
encodings and every existing fixture remain unchanged. This is not a change
to task validity or a resolution of GAP-23.

The existing Swift validator's depth boundary remains unchanged. In the
scanner's root-object cases, a property containing N nested arrays reaches
the scalar at depth N+1; N=999 is within the existing boundary and N=1000 is
not. A scanner unable to establish a deeper file as parseable reports
`unparsed`, not corrupt or invalid, and preserves all bytes. The scanner must
not pass a complete deeply nested object to Foundation object-model decoding;
it may decode only individually extracted scalar claim strings. The shared
`golden/legacy-task-inspection-deep.jsonl` vectors define byte encodings,
structure, malformed/duplicate cases and expected observations. Run those
vectors through the real scanner and existing validator in isolated test
processes; retain all earlier positive and invalid task/journal vectors.
For each row construct the exact JSON text
`{"device_id":"ble:old","unknown":` + N `[` bytes + `0` + N `]` bytes + `}`.
`missing_bracket` removes one closing `]`; `duplicate_device` inserts
`,"device\u005fid":"other"` immediately before the final `}`. Encode UTF-8
without a BOM, UTF-16LE with `FF FE`, or UTF-32BE with `00 00 FE FF`. Every
case also checks that inspection leaves the input bytes unchanged.
`duplicate_unknown` instead inserts `,"extra":{"x":1,"x":2}` immediately
before the final `}`. `leaf_empty_array` replaces the scalar `0` with `[]`;
`leaf_nonempty_array` replaces it with `[0]`. `check_valid` is the expected
result of the validator's stricter `check` mode on the same UTF-8 JSON text,
before any parent-record encoding conversion. It differs from the observation
for the duplicate-unknown case. An empty container at depth 1000 is accepted;
a value inside it is at depth 1001 and rejected by the existing boundary.
