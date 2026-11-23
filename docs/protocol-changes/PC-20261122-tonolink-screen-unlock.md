# PC-20261122 TonoLink unlock from the mirrored screen on iOS

```yaml
change: PC-20261122-tonolink-screen-unlock
contracts: [P07, P09]
status: frozen
breaking: false
base: 73005238e3eff1408c84a08af13723e2f82a8486
contract_revision: spec/device/v1/tonolink-board.md §4.4 at the commit that introduces this record
```

Protocol impact: P07; P09

## Trigger and delta

PC-20261117 removed automatic unlock because Apple ITMS-90699 rejected iOS 1.1 (5) for
registering a device lock notification (`com.apple.springboard.lockstate`). It also removed
the passcode itself, so a wake word on a locked phone ends at the passcode page: on
2026-11-22 the agent ran 13 steps there for 100 s and reported failure.

The owner's decision (2026-11-22): keep the lock notification out, and decide from the
mirrored screenshot instead. The passcode is typed only after the screenshot shows the
passcode page. The owning clause is TonoLink board §4.4; device panel §4.3 gets the input
back. Contract owner, iOS implementer and reviewer: Claude, in one session.

| | PC-20261117 | This change |
| --- | --- | --- |
| Lock signal | none (protected data only) | mirrored screenshot classified `passcode` / `lockScreen` / `other`; still no lock notification |
| Passcode | not stored | Keychain `com.tono.phonedsh.tonolink-passcode`, this device only, after first unlock |
| Typing | never | only when the post-wake screenshot is `passcode`; 3 failures a day stop it |
| No saved passcode | refuse while protected data is unavailable | same |

No wire change: the board's keyboard command grammar (`unlock_commands` in
`spec/device/v1/golden/tonolink-voice.json`) is the one already accepted by the firmware.
`ios_app_binary_forbidden_strings` is unchanged: the lock-state name and the old Keychain
service both stay out of the executable.

## Compatibility

| Path | Behavior |
| --- | --- |
| Old iOS → firmware | unchanged: no passcode commands are sent |
| New iOS → old or new firmware | existing `hid_mode` / `key` commands and acks |
| Old data → new iOS | a passcode saved before PC-20261117 is ignored; the owner saves it again |
| Rollback to old iOS | the new Keychain item and failure counter are ignored |

Android and firmware have no code changes.

## Acceptance

- `swift test --filter 'TonoLinkUnlockTests|IPhoneLockScreenTests'`: the command runner types
  nothing when the screen check says no; the classifier accepts only an unambiguous answer.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
- Device: locked phone with a saved passcode, wake word plus a phone task; the voice log shows
  `unlock: screen after wake = passcode` then `unlock: unlocked`, and the task runs.
- Not covered by this record: App Store review of a build that stores and types the passcode.
  Only the lock notification was named in ITMS-90699.
