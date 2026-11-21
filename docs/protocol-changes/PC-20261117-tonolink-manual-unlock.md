# PC-20261117 TonoLink manual unlock on iOS

```yaml
change: PC-20261117-tonolink-manual-unlock
contracts: [P07, P09]
status: frozen
breaking: false
base: 6ab3552d99c6b937a47e9d23513e10505e05f579
contract_revision: spec/device/v1/tonolink-board.md §4.4 at the commit that introduces this record
```

Protocol impact: P07; P09; P27: none — Bot row projection and user actions are unchanged.

## Trigger and delta

Apple ITMS-90699 rejected iOS 1.1 (5) for registering a device lock notification.
The iOS voice host and agent previously used it to send a Keychain passcode to
the board's keyboard. The owner now unlocks the phone in iOS. The agent
preflight stops before HID setup when protected data is unavailable, and
blind mirror recovery requires an active foreground app. The panel shows
hardware readiness. Voice admission keeps the existing durable delivery
rules and drops its wait for automatic unlock.

The contract owner, iOS implementer and reviewer are Codex. The owning
clauses are TonoLink board §4.1.1 and §4.4 and device panel §4.3. No wire
schema or version change. The shared TonoLink voice fixture keeps the
accepted and rejected legacy keyboard vectors and records the strings
forbidden in the archived iOS app executable.

## Compatibility

| Path | Behavior |
| --- | --- |
| Old iOS → new firmware | Existing keyboard command grammar and acknowledgements apply. |
| New iOS → old firmware | Voice, mirroring and permitted keyboard commands use their existing grammar. The host stops sending automatic passcode commands. |
| New iOS → new firmware | Same commands as with old firmware. Firmware advertises its existing capabilities. |
| Old data → new iOS or rollback | Existing outbox entries follow ordinary recovery. New iOS ignores any old passcode and attempt counter. No storage migration. |

Android and firmware have no code changes. The iOS app alone is rebuilt.

## Acceptance

- iOS paths owned by this change are the TonoLink voice host, agent preflight,
  phone-control panel, obsolete passcode store and lock device tests.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
  verifies contract consistency.
- `swift test --filter 'TonoLink(Voice|Unlock)Tests'` runs valid, invalid and
  refusal cases through Swift's real BLE codec and command runner.
- Archive the iOS Release app and read its archived executable against
  `ios_app_binary_forbidden_strings`. The archive must also verify its signature.
- On a fixture phone, `TonoLinkLockDeviceTests.testProtectedDataUnavailableStopsAgentPreflight`
  exercises the refusal of the real agent preflight. Physical device and BLE
  voice delivery must be recorded separately from archive and hosted checks.
