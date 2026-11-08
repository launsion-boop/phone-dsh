# Identity confirmation simulator test

This isolated XCUITest compiles the actual `BluetoothDevicesPage` and the real
BLE store into a test-only host. The host enables `PDSH_ENABLE_DEVICE_TASKS`
solely to render the experimental identity controls; it does not change the
probe app configuration. Its device-task manager is a fail-fast substitute:
any attempted task action terminates the test host. A simulated peer and a
unique UserDefaults suite exercise the real confirmation method. The test taps
the page button, checks the rendered failure and preserved value, then repairs
the test suite and verifies an explicit retry. It also exercises the real
page's unavailable and reconnect states after a simulated service change.
It does not invoke a target
identity RPC, start tasks, or connect a physical device.

Requirements: macOS with Xcode command-line tools, XcodeGen, Python 3, and an
available iOS 17 or later simulator runtime with an iPhone device type. A first
Swift package resolution may require network access and additional disk space.
The runner requires at least 2 GiB free on the output and checkout volumes and
on an explicitly supplied package-cache volume. It monitors them during
builds and tests. Avoid running another Swift build at the same time.

```sh
python3 examples/probe-app/identity-ui-harness/run.py
```

The runner creates a new output directory under the system temporary directory
and retains logs, the generated project, build output, and the `.xcresult` for
inspection. It creates a uniquely named simulator and shuts down and deletes
only that simulator. Use `--help` for explicit runtime/device-type selection,
an existing output parent, or an optional existing Xcode package cache. Xcode
may update a supplied package checkout; without that option the cloned source
packages are placed in the runner's new output directory. Xcode and SwiftPM
may still use their normal system caches. The checked-in spec uses relative
paths; the runner writes a private resolved copy and test-source copies for
XcodeGen while referencing the production page in the checkout.

A passing result is simulator evidence for this page and the local store. It
does not establish physical BLE behavior, authenticated identity, durable
storage, or task delivery.
