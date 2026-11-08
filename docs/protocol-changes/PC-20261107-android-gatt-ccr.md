# Contract change request: Android GATT callback identity and link security

```yaml
change: PC-20261107-android-gatt-ccr
contracts: [P07, P08]
status: draft
breaking: false
version_decision: pending — no Android GATT transport is approved or connected
base: eb50999dfcb3b83a8d8d99019ff1c8a689f03d5e
contract_revision: pending
```

The target Android Link channel requires each successful write callback to
identify the exact outstanding write, and ignores an old generation or write
token. On Android API 26–35, `BluetoothGattCallback.onCharacteristicWrite`
provides the GATT object, characteristic and status, but no application token,
request ID or bytes. The GATT object distinguishes connection generations, but
a delayed or duplicate callback for an earlier write to the same characteristic
cannot be distinguished from a callback for the current write on that same
connection using those parameters alone. Attaching the current token in an
adapter would assume a one-callback/no-late-callback guarantee that has not been
established. A fake callback test that always supplies the correct token cannot
prove that the actual Android API supplies this guarantee.

A separate issue is link-security evidence. The reference ESP32 firmware
requires an encrypted, bonded link at its server, but Android API 26–35 bond
state does not itself prove current-link encryption or authenticate arbitrary
legacy peers. A successful CCCD write or HELLO is likewise not proof of peer
identity or current link confidentiality. The newer Android public encryption
status API is not available across this app's minimum API level. Do not infer
application authorization, identity pinning or an authenticated task session
from bonding or discovery.

Before freezing a real Android GATT adapter, the owner must select and document
a verifiable callback/operation ownership model, exact timeouts and teardown,
API-level permissions, connection generation handling, security claims and
legacy interoperability. Any assumption about platform callback delivery must
be supported by authoritative API guarantees or recorded as a limitation, with
adversarial duplicate, stale, disconnected and delayed-callback tests. The
`platform-android` / `domain` module interface, ownership and lifecycle must
also be frozen with shared scenarios before implementation. If the platform
cannot provide a required property, the contract must not pretend that it can;
the adapter remains target-only. Device task traffic still requires the
separate authenticated session contract. No wire field, Android feature,
permission or production caller is added by this request.
