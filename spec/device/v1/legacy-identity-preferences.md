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

The old void insertion method remains as a compatibility wrapper and discards
the result; newer probe code uses the result-bearing method. Operations through
this API serialize participating callers within the current process. UserDefaults
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
