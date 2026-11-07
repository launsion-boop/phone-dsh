# Android BLE foreground discovery slice, v1

Status: `target`. This slice defines discovery only. It does not implement or
claim Bluetooth connection, identity, GATT, Link, tools, task grants, or P09
page parity. An advertisement, name, RSSI, platform address or bond is not
evidence of any of those. No target Link or task operation is called.

Only a visible page's explicit user action can initiate a scan. On Android API
26–30 the app declares the legacy Bluetooth permissions and requests fine
location for scanning; API 31+ requests `BLUETOOTH_SCAN` and asserts
`neverForLocation`. The app does not derive physical location from scan data;
this platform flag may filter some beacons. There is no background, advertise,
or Bluetooth-connect grant in this slice. Empty results do not mean permission
denial or prove that no device exists. The unfiltered Android system scan may
be suspended when the screen is off. Successful `startScan` return means only
that the call returned, not that radio coverage or delivery is guaranteed.

Each user attempt has a fresh generation and callback. Permission results,
scan callbacks, timers, and OS failures are serialized and accepted only for
their owning still-active generation. A pending permission request keeps its
original generation until the platform responds; a later request cannot claim
its result. Stop, page exit or host `ON_STOP` invalidates the local generation
before requesting system stop, discards late results and does not automatically
restart on resume. A scan has a 15-second monotonic deadline. Stop uses the
same callback instance as start. Errors, unavailable hardware, Bluetooth off,
denied permission and a successful scan with no results remain distinguishable.
Repeated start while starting or scanning does not create another scan.

At most 100 in-memory candidates are retained for a scan. The app uses a
private platform key only to coalesce repeated callbacks in that scan and
creates a random opaque identifier for display state; this identifier is not
stable across scans. An unknown advertisement name is rendered as unnamed;
name and RSSI are untrusted display text, not identification or capability.
The source must cap advertised names at 128 Unicode scalar values, replace
invalid scalar encodings, and bound its pending event buffer. Never display,
log, persist or transmit platform addresses or raw advertisements. Names,
RSSI and random identifiers may be displayed in the local discovery UI only;
they are not logged, persisted or transmitted. Candidates are cleared
when a new user scan begins and when the page is disposed; they never restore
after process restart. This differs from iOS's current cross-scan in-memory
retention and is not a claim of complete cross-platform parity.

If requesting system stop throws (including permission loss), local callbacks
remain invalid and the UI reports `CLEANUP_REQUIRED`; it must not claim the
system scan stopped. Keep the original callback for best-effort cleanup but do
not start another scan within that source instance. An exception-free retry is
not proof that the system stopped: implementations may forget the callback
before a failing stop and OS versions differ. Do not automatically retry or
silently clear this condition. A fresh process is a new source, not evidence
about the old process or radio; physical stop and power use remain unverified.
Even normal `stopScan` return is an unacknowledged OS request, not radio proof.

The shared Kotlin UI interface is `BleScanSource`; its state does not expose
platform objects or authenticated identities. `close()` performs local stop
and clears candidates on page disposal; it must preserve `CLEANUP_REQUIRED` if
system cleanup is unresolved. `SCANNING` means the platform
start call returned and local generation remains active, not that discovery
succeeded. `STOPPED` means local generation is invalidated and stop was
requested without a synchronous exception, not a platform acknowledgement.
The schema and `golden/android-ble-discovery.jsonl` prescribe real-state-machine
scenarios. Platform adapters must run them through their real implementation
with a controllable backend; host fakes do not establish Android radio behavior.
True Android devices and the reference peripheral are required for runtime
permission, lifecycle, discovery and stop observations.
