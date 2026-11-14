# Unlock a locked iPhone through the TonoLink board's keyboard

```yaml
change: PC-20261114-tonolink-unlock
contracts: [P07, P09]
status: implemented
breaking: false
version_decision: Additive and consumer-only. The phone starts using `cmd` lines the board already accepts (`hid_mode`, `key`, `type`); no new wire field, verb or firmware build. Older phones never send them.
base: origin/main e6718306
contract_revision: spec/device/v1/tonolink-board.md §4.4 and golden/tonolink-voice.json unlock_commands @ this branch
```

Protocol impact: P07; P09. P07 — §4.4 registers the phone's use of the board's existing keyboard lines over BLE to type the owner's numeric passcode while the phone is locked, with its order, settle times, stop-on-refusal and attempt limits. P09 — device-panel.md §4.3 lets the host put one section of its own above a device's tools; for a TonoLink board it is 手机控制 (readiness, and the only place the owner saves the passcode). `spec/ui/v1/pages/device-panel.json` regenerated.

## Trigger → current → expected

- Trigger: the owner wants the agent to keep controlling the phone when it is locked ("锁屏也能自动解锁").
- Current: a locked phone stopped every agent task; USB HTTP, which carries all taps and keys, may be cut by iOS while the phone is locked.
- Expected: with the owner's consent and saved numeric passcode, an agent task that starts on a locked phone types the passcode through the board's keyboard over BLE. Limits: one attempt per locked period, three failures a day.

## Measured on the phone before the design (board plugged in, `TonoLinkLockDeviceTests.testWhatWorksWhileLocked`)

| Question | Result |
| --- | --- |
| Lock without a person | AssistiveTouch → 设备 → 锁定屏幕 locks it |
| Does the app know it is locked | `isProtectedDataAvailable` turns false about 10 s after locking |
| USB HTTP right after locking | still up (iOS cuts USB accessories after about an hour locked) |
| AirPlay mirror | the picture stops while the screen is off and resumes when it wakes |
| USB HTTP after a long lock, once unlocked | unreachable until the owner allowed the accessory again: hence the precondition 锁定时允许访问 → 配件 on (§4.4) |
| BLE `hid_mode 1`, `key space` while locked | acked `ok`; the key brought up 输入密码 with a 4-digit keypad (the shipped sequence uses backspace, as the sibling xiaozhi-link does: it cannot add a character) |
| `com.apple.springboard.lockstate` | 1 within 3 s of locking; protected data turned unavailable after 12 s |
| Final live try | locked phone, one breath 你好小智，打开设置: lock seen at the wake, the turn recorded at once while the board unlocked the phone on a ctrl link of its own (7.7 s), the heard text waited for it, the agent opened Settings; reply 设置已打开 at 35.6 s |
| Third live try | unlocked (7.5 s), but the turn started recording only after the unlock and missed the command |
| Second live try | the lock was seen at the wake and the passcode typed with one `type` line, but only 3 of 4 digits arrived: the freshly shown keypad dropped the first. Now one `key` line per digit, 300 ms apart, after a 2 s wait |
| First live try | no unlock: the check ran at an agent task start, but a locked phone never starts the chat engine, and protected data alone missed the lock. Hence the wake-time unlock and the lock-state signal |

## Ends

| End | Change |
| --- | --- |
| Board firmware | none: `main/shared/pa_cmd_parse.c` already accepts these lines on `cmd`; `main/ctrl_svc.c` logs only the verb and result |
| Phone BLE library | `TonoLinkUnlock` (`Sources/PhoneDSHBLE/TonoLinkUnlock.swift`): validator, line builder, runner that stops at the first refusal |
| App | `TonoLinkUnlockStore` (Keychain item, this device only, after first unlock; failure count) and `PhoneLockState` (SpringBoard lock state or protected data); `TonoLinkPhoneControlSection` in the mini program; unlock at the wake in `TonoLinkVoiceHost` and at the start of `IPhoneAgentHost.prepare()` |
| Shared cases | `unlock_commands` / `unlock_rejected` in `spec/device/v1/golden/tonolink-voice.json`, fake passcodes |

## Compatibility

| Pair | Behaviour |
| --- | --- |
| New phone → current or older firmware | the grammar predates this change; a board that refuses a line stops the attempt with nothing retried |
| Old phone → any firmware | never sends these lines |
| Rollback of the app | the Keychain item and two UserDefaults keys stay unread |

## Security decisions

- Numeric passcodes only. The keypad ignores the wake space, so the space cannot become part of a wrong entry. Enter is sent only when the passcode is not 4 or 6 digits, because iOS submits those two lengths by itself.
- The passcode is typed only while iOS reports protected data unavailable. Typing on an unlocked phone could put the digits into an app's text field.
- The passcode never reaches the board's storage, a log, an error, a receipt or the model. The firmware logs the verb only.
- The owner turns it on explicitly. A reboot needs the owner's first unlock, because the Keychain item is unreadable until then.

## Evidence

- `swift test --filter TonoLinkUnlockTests` → PASS (shared vectors, rejected passcodes write nothing and are not echoed, order, stop on refusal or silence).
- Device: `testWhatWorksWhileLocked` and `testLockSignals` → PASS (tables above). `testLockedPhoneIsNotUnlockedWithoutConsent` skips itself while a passcode is saved (it would type it).
- With the owner's real passcode, run by the owner by voice on the locked phone: unlocked and the task completed (final live try above). The agent never typed or saw the passcode.

Not verified: the 3-failures-a-day stop on the phone, a 6-digit or longer passcode, an iPhone with Face ID.
