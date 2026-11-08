# Android BLE discovery + standard GATT: target → implemented

```yaml
change: PC-20261107-android-ble-standard-gatt
contracts: [P07, P08, P09]
status: implemented
breaking: false
version_decision: none — no wire field, frame, capability or persisted format; the Android Link channel, tasks and identity stay target (GAP-20)
base: 6cd5853c
contract_revision: this commit (spec/device/v1/android-standard-gatt.md, android-ble-discovery.md, golden/standard-gatt-decode.jsonl)
```

## 1. Identity and roles

- Trigger → current → expected: PR #59 added an iOS 蓝牙设备 page and Settings
  entry; Android had only an unwired scan state machine (`target`, no GATT), so
  P09 reported the page and entry missing. Expected: Android ships the same page
  for scan + standard GATT, with the Link/task half explicitly absent.
- The user directed this change on 2026-11-07 ("advance and build"); one agent
  held coordinator/contract owner, Android implementer and reviewer roles.
- Owning spec: [android-ble-discovery.md](../../spec/device/v1/android-ble-discovery.md)
  (status advanced), new [android-standard-gatt.md](../../spec/device/v1/android-standard-gatt.md),
  shared vectors `spec/device/v1/golden/standard-gatt-decode.jsonl`.
- Ends: Swift `StandardBLEProfile` (existing decoder, now also driven by the
  shared vectors in `StandardGATTDecodeVectorTests`); Kotlin
  `domain/connector/ble/StandardBleProfile.kt` (new, `StandardBleProfileTest`);
  Android app `AndroidBleDevices.kt`, `BluetoothHostBinding.kt`; lib
  `BluetoothDevicesPage.kt`, `PdshRoute.Bluetooth`, `SettingsDestination.BLUETOOTH`.

## 2. Contract delta

| Item | Before → After |
| --- | --- |
| Android BLE discovery status | `target`, no production caller, no manifest permission → `implemented`; the Bluetooth page is its one caller; manifest declares the scan/connect permissions |
| Android standard GATT | absent → allowlisted SIG profiles identical to iOS; one owner per `BluetoothGatt` generation; one outstanding op; read 10 s, connect+discovery 20 s; expired read closes the generation; grants reset per connection |
| Immediate Alert | iOS only → Android writes without response and reports `submitted_unconfirmed`, never executed |
| Shared fixtures | none for standard profile decoding → `standard-gatt-decode.jsonl` (16 valid, 18 invalid), consumed by both decoders |
| Link / tasks / identity / bonding / agent tools on Android | `target` → unchanged `target` (GAP-20) |
| P09 Bluetooth page | iOS-only → Android page; flag-gated device-task controls are excluded from extraction (`6cd5853c`); iOS 轻度/高度提醒 recorded in `_spec-required.json`; `device.name` header registered as runtime text on both platforms |

Self-check (baseline §5.1): no second representation, no new wire field, no
enum on a shared wire; the decode vectors pin existing iOS behaviour.

## 3. Compatibility

| Producer → Consumer | Decision |
| --- | --- |
| old app → peripheral | unchanged (no Android BLE before) |
| new Android app → standard peripheral | only allowlisted reads and one Alert write; no bonding initiated; an encryption-required read fails visibly |
| new Android app → PDSH Link firmware | Link not opened; the page shows only standard profiles |
| persisted data | none: candidates, grants and readings are in memory only |

Rollback: removing the route and manifest permissions restores the previous
state; no stored data depends on it.

## 4. Verification

| Command / run | Result |
| --- | --- |
| `swift test --filter StandardGATTDecodeVectorTests` (macOS arm64) | PASS: 34 shared vectors through the real Swift decoder |
| `./gradlew :domain:testDebugUnitTest` (galic, JDK 17, SDK 35) | PASS: 152 tests incl. `StandardBleProfileTest` on the same vectors |
| `./gradlew :lib:testDebugUnitTest` | PASS: 1006 tests (two Settings tests now scroll to the exact node they click; destination inventory gains `BLUETOOTH`) |
| `./gradlew :app:assembleDebug` | PASS |
| `cargo build -p pdsh-jni` (host) + `./gradlew :app:testDebugUnitTest` | PASS: 301 tests incl. `BleScanMachineTest`, `BlePermissionRegistryTest` |
| `page_structure_check.py --page bluetooth-devices` | PASS: 0 divergences |
| Redmi 22041216C, Android 14 / API 34, side-by-side debug install `com.phonedsh.app.pr59test` | Settings → 蓝牙设备 renders; scan permission prompt → real scan found 12–14 advertisers; connect permission prompt is separate and requires a fresh tap; connect + discovery to a macOS CoreBluetooth test peripheral (`PDSH-MacTest`) found Immediate Alert and the Mac's own Device Information; both grants start off; a peer-initiated disconnect (GATT status 19) is shown and resets grants |
| Same device: Activity recreation | FAIL before fix: the store kept the destroyed host's closed scan lease, so scanning did nothing. Fixed by counting mounted routes and closing a lease whose host changed (`AndroidBleDevices.reconcile`); scan after a fresh launch verified, recreation itself NOT re-run |
| Same device: grants, reads, alert (test peripheral re-published with 181A temperature 0x0934 / humidity 0x11D7) | PASS: discovery listed manufacturer, model, temperature, humidity, alert; with grants off the read/alert rows are disabled; after granting, `temperature` → `23.56°C`, `humidity` → `45.67%`, `manufacturer` → `Apple Inc.` (the Mac's own 180A); 轻度提醒 reached the peer as `write 2A06 = [1]` |
| Same device: grant row | FAIL then fixed: only the Switch thumb toggled; the whole row is now `toggleable` (verified by tapping the label) |
| Same device: Home and return | PASS: a new scan runs after returning (11 advertisers) |
| macOS test peer | Ends every link about 50 s after connect (GATT status 19); the page reports it and resets grants. This is the peer, not the phone |

Not covered: ESP32 firmware peripherals, a real battery service
(macOS refuses to publish 180F from an app), Activity recreation re-run after the fix, other OEMs, API < 34,
background / screen-off behaviour, and process death during a read.
