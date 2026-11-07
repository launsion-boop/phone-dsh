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
