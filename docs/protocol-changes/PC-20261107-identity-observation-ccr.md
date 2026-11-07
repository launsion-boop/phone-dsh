# Contract change request: observable identity transitions

```yaml
change: PC-20261107-identity-observation-ccr
contracts: [P07, P09, P18]
status: draft
breaking: false
version_decision: pending; no production change is approved by this request.
base: db2fe655b4a974d613b591d4cec67c04801a8a4a
contract_revision: pending
```

The frozen [legacy preference amendment](PC-20261107-legacy-identity-preservation.md)
requires stale confirmation results not to modify a replacement connection.
A candidate implementation was reviewed before it was committed. Its
per-device epoch checks after UserDefaults access prevent some stale writes,
but ordinary `@Observable` device/status mutations can notify observers
synchronously before the actual mutation. An observer may clear a connection,
replace a channel/client, or replace a pending value during that notification;
the outer mutation can then apply an old value after the replacement. Merely
blocking reentrant confirmation, or checking the epoch before the observable
setter, does not establish the frozen postcondition. Dropping a genuine
disconnect or replacement is also unacceptable.

The observation ordering is supported by the Swift upstream
[`Observable` macro](https://github.com/swiftlang/swift/blob/main/lib/Macros/Sources/ObservationMacros/ObservableMacro.swift)
and [`ObservationRegistrar`](https://github.com/swiftlang/swift/blob/main/stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift)
source. An isolated Swift 6.4 macOS model has since exercised a synchronous
observation callback that disconnects during a devices or status mutation:
the ordinary setter overwrote the disconnect, while a conditional mutation
that checked the epoch inside the mutation closure preserved it. This model
does not execute `BLEDeviceStore`, CoreBluetooth, or an iPhone and is not a
device reproduction or acceptance evidence for the candidate.

One unapproved approach is a conditional observable mutation whose generation,
client and pending checks occur inside the registrar mutation closure, after
the `willSet` notification and before touching backing storage; status updates
need the same protection. Another possibility is a proven serialized event
design with immediate invalidation and no lost lifecycle events. Either must
define all direct `devices`/`status` writes, sync reentry and exception paths,
and must be validated on the actual Swift toolchain and iOS before selecting
it. Do not assume a macro-generated storage name or a simulated observer proves
this design safe. Guarding confirmation alone does not prove the surrounding
proof, clear-connection and discovery mutations safe: each can publish more
than once or alter pending operations while a replacement is installed. Their
ordering and possibly repeated reentrant disconnects also need an explicit
decision; no lifecycle event may be silently discarded.

Review also identified operations whose lifetime must be accounted for before
freezing the transition: a disconnect currently cancels and fails resources
while it is still clearing tables by device UUID; a callback can install a
new generation during that work. A stale channel failure and an old task's
`linkBusy` cleanup likewise refer only to the UUID. Standard-read completion
also publishes a device update before finishing the pending operation. A
repair must establish ownership of the captured generation and operation at
each callback and suspension point, and must not clear or finish a newer
operation. It must explicitly account for CoreBluetooth delegate callbacks
that do not themselves contain an application generation. These findings
are source review, not proof that every listed interleaving occurred at runtime.

Further review shows that re-looking-up the device by UUID after a notification
is necessary but not sufficient. A reentrant grant revocation can be
overwritten by an older grant within the same connection generation. The
first of the two current `clearConnection` device publications can reenter a
new connect, after which the old clear still removes the UUID's timer and
characteristics and publishes a second disconnected state. A standard-read
callback publishes a reading before its unqualified `finish`; a reentrant
cancel or new read can change which continuation is current. A timeout or old
channel failure can publish status and then disconnect by UUID after an
observer has installed a replacement. A handshake can similarly continue
after its first publication has caused a disconnect. These are source-derived
interleavings, not physical-device reproductions.

The grant case has since been reproduced on macOS Swift 6.4 using an isolated
XCTest with the real `BLEDeviceStore(testDevices:)` and
`withObservationTracking`: an outer `grant(read: true)` notified an observer
that synchronously called `grant(read: false)`, but the final device still had
`allowRead == true`. The regression expecting the later revocation to win
failed. This used no central manager, peripheral, radio or user preferences;
it demonstrates the local state ordering defect, not physical BLE behavior.

The owner must decide per-device publication revision and resource ownership,
not only an identity epoch: genuine clear/revocation must take effect before
callbacks, old resources must be detached and handled without deleting new
ones, and pending continuations and busy operations must be completed or
released only by their owners. Current `linkBusy` is a UUID set and is not
cleared by `clearConnection`; if a repair starts clearing it on disconnect,
an older async defer must not remove a newer operation's busy ownership.
CoreBluetooth delegate callbacks themselves do not carry an application
generation, so an app-local epoch alone cannot prove which radio connection
caused a callback. The future contract must explicitly state that limitation
and fail-closed behavior rather than asserting radio attribution or liveness.

Apple documents a potential disconnect boundary: after
[`centralManager(_:didDisconnectPeripheral:error:)`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanager%28_%3Adiddisconnectperipheral%3Aerror%3A%29?changes=_5)
executes, the peripheral delegate receives no further calls and its services
and characteristics are invalidated. Apple also documents that
[`cancelPeripheralConnection(_:)`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection%28_%3A%29?changes=_2_1__2_8&language=objc)
is nonblocking and pending commands may not complete. A candidate is therefore
to quarantine a cancelled read and block a new attempt for that peripheral
until a matching, applicable disconnect callback has completed, then reconnect
and rediscover. Cancellation itself is not that boundary. The applicability of
this rule to failed or cancelled connection attempts, callback ordering across
reconnection, and reads on notifying characteristics still needs a frozen
state machine and device/OS evidence. This source review does not establish
peer identity, encryption, radio freshness or production implementation.

Required evidence: real `withObservationTracking` tests that trigger
disconnect, channel/client replacement and same-spelling pending replacement
from both device and status notifications during successful and failed
confirmation, plus stale asynchronous proof; demonstrate no old state or
status overwrites the new generation and no lifecycle event is lost. Run the
shared valid/invalid preference fixtures against isolated real UserDefaults,
the reentry fixtures against a controlled spy, the actual store tests, release
build and applicable spec/P0/cross-tree gates. Cross-process UserDefaults,
hidden values and durable recovery remain unproven. BLE task grants stay
disabled.

The uncommitted candidate and its provisional transition fixtures were saved
outside the worktree as a local patch for later investigation; they are not an
implementation or acceptance result. Local storage was below 2 GiB, so no
Swift build or XCTest for that candidate was run at that time. The branch now
implements and tests the storage subset, but retains the old confirmation and
observation behavior; this CCR does not authorize enabling the target session
or declaring the preservation amendment implemented.
