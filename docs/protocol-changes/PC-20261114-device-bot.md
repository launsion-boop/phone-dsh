# One Bot per connected device; the TonoLink voice turn goes to the board's Bot

```yaml
change: PC-20261114-device-bot
contracts: [P07, P09]
status: implemented
breaking: false
version_decision: No wire or profile-format change. The device-to-Bot pair is a phone-local map; Bots are created through the existing createBot path.
base: origin/main 908d582b
contract_revision: spec/device/v1/tonolink-board.md §4.1 (where the heard text goes) @ this branch
```

Protocol impact: P07; P09; P27: none — Bots are created through the existing createBot path and the shared Bot profile and rows are unchanged; the device pair is a phone-local map. P07 — §4.1 now says the board's heard text goes to the board's Bot (current chat as fallback). P09 — the Bot info page gains a 设备 section that opens the device's mini program.

## Trigger → current → expected

- Trigger: the owner finds Bots easier than sessions and wants "connect a device → get a Bot".
- Current: device tools are granted app-wide; the TonoLink voice turn goes to whichever chat session is open.
- Expected:
  - The first time a Link device lists its tools, the phone creates a Bot for it, with no form to fill. The Bot is named after the device (TonoLink: 手机助手) and has a description of what the device does.
  - Voice from the TonoLink board goes to that Bot.
  - The Bot's info page links to the device's mini program.
  - Deleting the Bot creates it again at the next connection; forgetting the device keeps the Bot.

## Ends

| End | Change |
| --- | --- |
| App | `DeviceBotRegistry` (phone-local map; the TonoLink board's Bot is made when its voice link connects, other Link devices' when they list tools), `BotProductionHub.chatModel(ensuring:)`, `TonoLinkVoiceHost.answerThroughBot`, `BotInfoPage` 设备 section |
| Board firmware, Bot profile, desktop | none |

## Compatibility

| Pair | Behaviour |
| --- | --- |
| Older app data | no map: each Link device gets a new Bot at its next connection |
| No Bot runtime (engine not started) | voice falls back to the current chat |
| Desktop sharing the Bot roster | sees an ordinary Bot (no new fields) |

## Evidence (real phone, TonoLink board)

- The board's voice link connected and the 手机助手 Bot was created; its id is kept on the phone.
- Two earlier builds created a second 手机助手, because the app was killed before UserDefaults was written. Now the registry binds an existing Bot with the same name and description, and synchronizes at once.
- Voice test 你好小智，今天星期几: wake at 15:22:11, the text went to 手机助手, the reply 「今天是星期天，2026 年 11 月 15 日…」 came at 5.9 s and was spoken.
- After an app restart, reaching the Bot runtime took 26 s.
- In the background, four fixes were needed before the board's Bot answered:
  1. Start the Bot's runtime unit before sending, because after a relaunch only the selected Bot runs.
  2. Start the engine before sending, because a process relaunched in the background has the Bot runtime but no engine. The board's keep-alive makes starting it allowed.
  3. Pull the Bot's durable rows while waiting, because its chat model's feed pauses in the background and for Bots that are not on screen.
  4. Take only the answer that follows this turn's own message.
- Final background test (another app in front): heard at 16:18:52, engine up and Bot reached at 16:19:04, answer 「今天是 2026 年 11 月 15 日，星期日」 spoken at 41 s.

Not verified:
- Link devices other than the TonoLink board, where a Bot is created from `tools/list`.
- A Bot deleted and created again.
- The desktop's view of the new Bot.
