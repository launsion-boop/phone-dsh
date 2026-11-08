# Legacy BLE identity preference preservation

Status: `legacy` format; the preservation amendment is frozen in
`PC-20261107-legacy-identity-preservation`. This is not an authenticated
identity, pairing, migration, receipt recovery, or permission to run tasks.

Older draft phones store public labels at the UserDefaults key
`pdsh.ble.trustedIdentities`. The intended value is an array of strings. The
strings are historical labels, not proof that a BLE UUID belongs to a public
key or that any past plaintext traffic was authenticated. When a visible
valid array is used, its elements, including UUID-form or otherwise
unrecognized values and duplicates, are not deliberately renamed, normalized,
reordered or removed. This is not a guarantee about hidden or unreadable data.
For compatibility, duplicate
and membership comparisons use Swift `String` equality, including canonical
Unicode equivalence; they do not rewrite the original spelling.
The probe's draft `pendingIdentity` and `taskIdentity` fields are local UI
markers; recording or finding a label does not bind a UUID to a key or grant
task access. The current proof helper's existence is not evidence that it ran.

An insertion checks the effective value visible through UserDefaults before writing. If
it is absent, insertion may create an array; if it is an array containing only
strings, insertion appends a missing string or leaves a duplicate unchanged.
If a present value is any other type, including an array containing a non-string,
insertion fails and must not replace it. A duplicate requires no write. A new
write returns success only if a same-process readback has exactly the requested
array order and Unicode scalar sequences; a failed or mismatching readback
returns failure. A failure after `set` is not proof that no write occurred and
must not trigger an automatic rollback. The UI must not report
or retain the pending identity as recorded on failure. A membership query for
an absent or visibly invalid value remains false.

Confirmation captures a non-reusable local confirmation generation, the
current Link client instance and exact pending-label scalar sequence before
accessing UserDefaults. Connection clearing, channel replacement, installation
of a Link client, and replacement or clearing of the pending proof all invalidate
that generation. Because UserDefaults access may synchronously reenter the
store, after either insertion outcome the store updates identity or status only
if the generation, client instance and pending label are still the same. A
late result never changes a newer connection or restores a task grant. If the
preference write already happened, do not roll it back merely because the
connection changed; it remains only an unbound historical label. This is an
app-observed local ordering check, not evidence of radio liveness, bonding,
peer identity, or an authenticated session. The unused proof helper must also
discard its asynchronous result if its captured generation or client changed.
`golden/legacy-identity-confirmation.jsonl` describes these ordering cases.

### Observable confirmation and guarded submission

The local confirmation publication is ordered by a non-reusable identity
revision and confirmation attempt, in addition to the connection owner,
current Link channel and client, and the exact Unicode scalar sequence of the
pending label. Clearing or replacing a connection or channel, installing a
client (even the same instance), and setting or clearing pending (even to the
same scalar sequence) invalidate earlier identity revisions. A later accepted
confirmation invalidates an earlier attempt. Other devices have independent
revisions. An invalidated operation cannot change the current device's
identity, pending label, permissions, error or global status.
Installing or replacing a channel or client also clears the previous pending
and recorded UI markers; a marker established under the old object cannot be
confirmed under its replacement. Invalidate marker provenance before changing
the object reference or notifying observers; admission checks provenance,
not just whether an old marker remains temporarily visible during notification.

The confirmation-specific storage operation shares the existing process
lock, visible-value rules and exact-scalar readback with the public insertion
API. After reading the effective value and immediately before submitting a
new `set`, it checks the captured local state on the main actor, without
suspending or calling UserDefaults from that check. If it is already stale,
it performs no `set` and publishes no outcome. A duplicate or invalid visible
value is likewise not reported by a stale confirmation. Once `set` is entered,
its own synchronous callbacks can invalidate the operation before the
underlying write completes; the caller must not assume the write was
cancelled and must never roll it back automatically. A stale result after
`set` or readback is not reported to the replacement connection. After `set`
returns, a stale operation does not start a readback; if invalidation occurs
inside an already-started readback, it discards that readback's result.

A same-thread synchronous nested confirmation while another participating
preference operation holds the process lock is refused without accessing preferences,
starting a new attempt or publishing an additional identity result, including
precondition errors. The reentry decision precedes any such publication or
attempt allocation. An
explicit later retry is allowed. Other threads still wait under the existing
public storage API; confirmation and its validity check run on the main actor.
Real disconnect, replacement and revocation
callbacks remain effective during such reentry; no rule promises that
UserDefaults callbacks cannot publish Observation notifications or that
arbitrary external lock interactions cannot deadlock.

On a current successful confirmation, publish the historical label and clear
the pending marker. On a current storage failure, retain the pending marker,
show a device-specific failure and do not say that it was recorded. A missing
pending label or client produces a device-specific precondition failure for
an existing device; a missing device is a no-op. These confirmation outcomes do
not write the global Bluetooth status. Publication must recheck the captured
state inside the actual Observation mutation, after synchronous will-change
observers have run. A later accepted nested confirmation or lifecycle change
must not be overwritten by an older publication. The device-specific error is
cleared on a new connection or identity replacement and does not authorize a
task. The dormant proof helper must apply the same ownership checks after its
asynchronous result and any preference lookup; tests may feed its shared local
completion transition but must not invoke the target identity RPC or treat a
locally supplied result as a verified peer.

`golden/legacy-identity-observation.jsonl` specifies shared ordering cases,
including pre-submit invalidation, in-set uncertainty, Observation reentry,
same-value ABA and stale proof completion. These are local state and visible
preference rules, not authentication, durable storage or radio attribution.
Its result category describes observable effects of the void API, not a
test-only return value. Each hook runs once, while an Observation tracker may
receive nested notifications up to the case's stated bound. NFC/NFD labels
are synthetic unbound local markers used only to exercise scalar ordering;
they are not claimed to be outputs of a verified proof. The proof-completion
cases use a syntactically valid `ble:` plus 64 lowercase hexadecimal label.
The original confirmation vectors' interrupted success/failure cases inject
their interruption inside an already-started readback, returning the stated
success or injected failure; the new vectors cover earlier cancellation.
`lifecycle_actions` counts invoked hook actions; `lifecycle_transitions`
counts real state changes, so an ABA action must make two changes rather than
reassigning the same value. Preference access counts include the operation,
its synchronous nested calls and any explicit retry, but exclude the test's
subsequent independent inspection of the isolated suite. For every
`device-will-change` hook, register actual Observation tracking and invoke
the hook from its notification, not directly from the test. Observe global
status notifications as well as its final text: only the explicitly expected
radio-state event may publish status. Establish the status baseline via the
real powered-on state transition before installing the observer. The
no-client precondition case uses a reachable empty pending marker and no
client; the no-pending case has a current client and empty pending. Separate
installation-notification tests must prove an old still-visible pending
marker cannot be admitted for a new client. In the explicit-retry case, the
hook attempts B once while A holds storage; B's retry occurs only after A's
entire confirmation returns and releases that lock.

The old void insertion method remains as a compatibility wrapper and discards
the result; newer probe code uses the result-bearing method. Operations through
this API serialize participating callers within the current process. A
synchronous reentrant call on the same thread during an operation is refused
without reading or writing: membership and the result-bearing insertion return
false and the old void wrapper discards that failure. Other threads wait for
the current operation. The caller can explicitly retry a refused insertion.
`golden/legacy-identity-reentrant.jsonl` specifies these cases. UserDefaults
does not expose an atomic cross-process transaction or a reliable distinction
between a genuinely absent value and all lower-level unreadable/corrupt storage
cases. A successful readback is not proof of durable flush, cross-process
isolation, authenticated identity, or restart recovery. The effective value
can come from a registration, managed, volatile or other search domain; a write
may create or shadow a value in a different persistent domain and may affect
hidden old data. External/older writers can race; do not claim those cases are
protected. This amendment does not explicitly remove or clear the key, does
not authorize replay, and does not enable BLE task grants.
`golden/legacy-identity-preferences.jsonl` defines the shared visible-value
cases; tests must drive the actual UserDefaults API in isolated suites.
