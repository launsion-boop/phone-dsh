# Android standard GATT slice, v1

Status: `implemented` for the Android app's Bluetooth devices page; runtime
evidence is in [PC-20261107-android-ble-standard-gatt](../../../docs/protocol-changes/PC-20261107-android-ble-standard-gatt.md).
This slice builds on [Android BLE discovery](android-ble-discovery.md). It does
**not** implement or claim the PDSH Link channel, Link tools, device tasks,
device identity, pairing/bonding, agent tool exposure or any write that needs a
GATT response. GAP-20 (per-write callback ownership and link-security evidence)
stays open and keeps all of those `target` on Android.

## Profiles

The allowlist, service/characteristic UUIDs, units and decoding are the iOS
`StandardBLEProfile` (`Sources/PhoneDSHBLE/StandardBLE.swift`); this file does
not restate them. Both ends decode the shared vectors in
`golden/standard-gatt-decode.jsonl`: each line has `profile` + `hex` and exactly
one of `value` (the exact display string) or `error`, or `alertLevel` with
`hex` (the command byte) or `error`. Numbers are formatted as the shortest
round-trip decimal of the IEEE double with at least one fractional digit for
temperature/humidity (`23.5`, `-10.0`, `0.0`); battery is an integer string.
Device information text must be strict UTF-8, 1–512 bytes, without NUL; an
invalid sequence is an error, never replaced.

No other service or characteristic is read or written. Vendor-private services
are reported as "no standard capability", never probed.

## Connection ownership

- Only an explicit user action on a visible Bluetooth page connects a scan
  candidate. The candidate's opaque id is resolved to the platform device only
  through the process scan owner; the platform address is never displayed,
  logged, persisted or transmitted.
- Each connect creates a new generation owned by exactly one `BluetoothGatt`
  object. A callback whose `BluetoothGatt` is not the current generation's is
  ignored. Disconnect, timeout, failure or page disposal closes that object;
  a new connect always creates a new one.
- Connect plus service discovery has a 20-second deadline; on expiry the
  generation is closed and the page reports `连接或服务发现超时`.
- Android does not initiate bonding. A peripheral that requires an encrypted
  link fails its read with an insufficient-authentication/encryption status,
  which is shown as a read failure, not as success.

## Grants

`允许读取标准数据` and `允许提醒控制` default to off and reset on every new
generation (`每次建立新连接后，请重新授权…`). On Android they gate only the
manual buttons on this page; no agent tool is exposed, so the page states that
agent access is not available on Android.

## Reads

At most one GATT operation is outstanding per generation. A read is accepted
only while connected, with the read grant on, for a discovered profile that has
the read property. Its result is accepted only from the current generation, for
the exact characteristic object of the pending read, while that read is still
pending. A read has a 10-second deadline; on expiry or a non-success status the
read fails. Because Android read callbacks carry no request token, an expired
read closes the generation (fail closed) rather than leaving a late callback
that could be attributed to a later read.

## Immediate Alert

Levels 0–2 are written once with `WRITE_TYPE_NO_RESPONSE` to the discovered
Alert Level characteristic, only with the alert grant on. A successful local
submit is reported as
`submitted_unconfirmed: Immediate Alert has no application acknowledgement; inspect device before repeating.`
It is never retried automatically and never reported as executed.

## Permissions

API 31+: `BLUETOOTH_SCAN` (`neverForLocation`) for discovery and
`BLUETOOTH_CONNECT` requested at the first connect. API 26–30: legacy
`BLUETOOTH`/`BLUETOOTH_ADMIN` and `ACCESS_FINE_LOCATION`, all with
`maxSdkVersion="30"`. A denied permission is reported; nothing retries it
automatically.
