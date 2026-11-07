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
