# Android BLE foreground discovery slice, v1

Status: `target`. This slice defines discovery only. It does not implement or
claim Bluetooth connection, identity, GATT, Link, tools, task grants, or P09
page parity. An advertisement, name, RSSI, platform address or bond is not
evidence of any of those. No target Link or task operation is called.
Until real Android and peripheral runtime evidence is reviewed and this
profile is explicitly advanced from `target`, production app and UI callers
must not instantiate or invoke this discovery source. Its new scan/location
permissions must not be added to the production manifest solely for this
target. The internal implementation and its tests may be retained unwired.

Only a visible page's explicit user action can initiate a scan. On Android API
26–30 the app declares the legacy Bluetooth permissions and requests fine
location for scanning; API 31+ requests `BLUETOOTH_SCAN` and asserts
`neverForLocation`. The app does not derive physical location from scan data;
this platform flag may filter some beacons. There is no background, advertise,
or Bluetooth-connect grant in this slice. Empty results do not mean permission
denial or prove that no device exists. The unfiltered Android system scan may
be suspended when the screen is off. Successful `startScan` return means only
that the call returned, not that radio coverage or delivery is guaranteed.

The process owns a single coordinator, worker, pending permission request and
quarantine. Each Activity gets a new, non-reusable host token and each page
mount gets a new, non-reusable page lease. Each attempt is owned by exactly
one host, page and generation. A host may start only while started; its return
to foreground permits a new user action but never restarts a scan. A late stop
from host A or dispose from page A must not stop, clear or otherwise modify a
new attempt owned by host/page B. A page close permanently invalidates only
that lease and clears only its own candidates. Results from one page are not
published to another. A different owner attempting to scan while an active
owner's permission, start, scanning or stop is occupied sees `BUSY`, no
candidates, and no automatic retry. A cancelled owner's still-pending system
permission result instead produces `PERMISSION_PENDING` for a new attempt.
`HOST_INACTIVE` indicates the owning host is not started. Once the
resource is free, a waiting owner's state becomes `IDLE` without starting;
a fresh user action is required. At most one candidate set
of 100 is retained in the process; a new owner starting clears the previous
owner's retained candidates, but old owners cannot clear the new set.
Process-wide quarantine is
visible to all leases and survives closing/reopening a page or Activity.
Permission launch is routed to the owning live host, not a process-global
last-attached Activity; its result remains bound to the original owner. Host
and page ownership is tested through the actual process coordinator and facade,
not by simulating repeated calls on one lease.

Each user attempt has a fresh generation and callback. Permission results,
scan callbacks, timers, and OS failures are serialized. Discovery data and
ordinary callbacks are accepted only for their owning still-active generation.
An invalidated generation's registered start/stop completion may be consumed
only to finish its cleanup and publish its terminal state; it cannot modify a
new generation. An old permission result may be consumed to release its pending
request but cannot start a scan. A pending permission request keeps its
original generation until the platform responds; a later request cannot claim
its result. While the original generation is still active and requesting
permission, repeated start is a no-op; its eventual grant may continue that
original attempt. After that generation is invalidated, a new user action while the old request is pending reports
`PERMISSION_PENDING`, launches no new request, and does not start when the old
answer arrives. A fresh user action is required after the answer is consumed.
Permission result registration must use a request-specific key that is never
reused by a new generation; Activity recreation restores old registrations
before accepting results, and any result whose owner is unknown is discarded.
Restored results never automatically start a scan. If the Android platform
cannot preserve this ownership across recreation, the adapter must fail closed
and this slice remains unimplemented until a reviewed revision resolves it.
Install request ownership before registering a callback because registration
may synchronously deliver a cached result. Test the actual registration seam,
including reentrant delivery, rotation and an unowned restored result.
Stop, page exit or host `ON_STOP` invalidates the local generation
before requesting system stop, discards late results and does not automatically
restart on resume. Immediately before invoking platform start, record a
15-second absolute deadline using Android `SystemClock.elapsedRealtime` (which
includes device sleep). Check that deadline when handling a start result and
every candidate or batch, not only when a timer callback arrives. If it has
expired, invalidate and clean up before publishing any start or discovery
result. The timer may run late if the process is frozen or the device sleeps;
it does not promise a radio stop at the deadline. Recheck elapsed time at the
next relevant event, including host start and screen-on, and request stop if
expired. After the deadline no discovery result is accepted. Physical stop
time and background power use require device evidence. Expiration during `STARTING` invalidates
locally and enters `STOPPING`; once start returns, request stop with the same
callback, or quarantine on exception. Stop uses the
same callback instance as start. Errors, unavailable hardware, Bluetooth off,
denied permission and a successful scan with no results remain distinguishable.
Recheck the required scan permission when platform start returns, on each
candidate, and on host start or screen-on. If permission has been revoked,
invalidate locally and request stop; a stop exception requires quarantine.
An ordinary app has no guaranteed immediate permission-change callback here;
without a relevant event the UI may temporarily show the previous state.
Repeated start while starting or scanning does not create another scan. The
owner establishes the generation synchronously and invokes potentially
blocking platform start and stop calls on the same serialized worker; local
invalidation never waits for that worker on the UI thread. The public phase is `STARTING`
until that call returns. A stop after or during start invalidates local delivery
immediately, reports `STOPPING`, and blocks further starts until the start has
returned and a stop using that same callback has completed. A timed-out
or abandoned start cannot release this reservation while its outcome is
unknown. Candidate events received while start is in flight are dropped;
an asynchronous scan failure invalidates locally and enters `STOPPING`, then
is reported as failed once start returns and the stop request has returned.
No discovery result can be published after invalidation.

At most 100 in-memory candidates are retained for a scan. The app uses a
private platform key only to coalesce repeated callbacks in that scan and
creates a random opaque identifier for display state; this identifier is not
stable across scans. An unknown advertisement name is rendered as unnamed;
name and RSSI are untrusted display text, not identification or capability.
The source must cap advertised names at 128 Unicode scalar values, replace
invalid scalar encodings, and bound its pending event buffer. Never display,
log, persist or transmit platform address fields or raw advertisements. An
untrusted name may itself contain address-like text; this does not promise to
sanitize all arbitrary text. Names,
RSSI and random identifiers may be displayed in the local discovery UI only;
they are not logged, persisted or transmitted. Candidate and snapshot default
string representations redact their values; callers must not explicitly log
their fields. This does not prevent external consumers from doing so.
Candidates are cleared
when a new user scan begins and when the page is disposed; they never restore
after process restart. This differs from iOS's current cross-scan in-memory
retention and is not a claim of complete cross-platform parity.

An exception from the platform start call does not prove it had no side
effects. Preserve its scanner and callback, invalidate the local generation,
and enter process-wide `CLEANUP_REQUIRED` without an automatic retry; this
quarantine survives page and Activity recreation just as a stop failure does.
A permission check
that fails before entering that platform call does not register a callback.

If requesting system stop throws (including permission loss), local callbacks
remain invalid and the UI reports `CLEANUP_REQUIRED`; it must not claim the
system scan stopped. Keep the original callback for best-effort cleanup but do
not start another scan anywhere in the same app process, even after page or
Activity recreation. A process-owned scan coordinator retains this quarantine
and the old scanner/callback; closing the page cannot discard it. An exception-free retry is
not proof that the system stopped: implementations may forget the callback
before a failing stop and OS versions differ. Do not automatically retry or
silently clear this condition. A fresh process is a new source, not evidence
about the old process or radio; physical stop and power use remain unverified.
Even normal `stopScan` return is an unacknowledged OS request, not radio proof.

The shared Kotlin interface is `BleScanSource` for a host and `BleScanSession`
for each page; the session state does not expose platform objects or
authenticated identities. `hostStarted()` and `hostStopped()` affect only
their own host. `close()` performs local stop
and clears candidates on page disposal; it must preserve `CLEANUP_REQUIRED` if
system cleanup is unresolved. `STARTING` and `STOPPING` are local asynchronous
operations; neither asserts radio state. `SCANNING` means the platform
start call returned and local generation remains active, not that discovery
succeeded. `STOPPED` means local generation is invalidated; if platform start
was invoked, the stop call returned without a synchronous exception, while an
attempt cancelled before platform start needs no stop. It is not a platform
acknowledgement.
The schema and `golden/android-ble-discovery.jsonl` prescribe real-state-machine
scenarios. Platform adapters must run them through their real implementation
with a controllable backend; host fakes do not establish Android radio behavior.
True Android devices and the reference peripheral are required for runtime
permission, lifecycle, discovery and stop observations.
