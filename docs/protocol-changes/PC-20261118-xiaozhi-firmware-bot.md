# PC-20261118 Xiaozhi firmware Bot (DEBUG)

```yaml
change: PC-20261118-xiaozhi-firmware-bot
contracts: [P07, P26, P09]
status: frozen
breaking: false
base: 88a9b4c4a1d39fc23b0881640bf9f5878a8739ee
contract_revision: spec/device/v1/xiaozhi-firmware.md at the commit that introduces this record
```

Protocol impact: P07; P26; P09; P13: none — the export reuses the existing import RPCs unchanged;
P18: none — nothing is persisted in UserDefaults (device records and staged images are in memory,
built images in Documents).

## 1. Identification and roles

- **Trigger → now → expected:** the owner wants a board running upstream xiaozhi to get a Bot that
  edits, builds and flashes its firmware from the phone. Now the firmware builder is a DEBUG page
  with no source input, and the phone has no way to deliver an image to a xiaozhi board. Expected:
  a DEBUG OTA relay on the Wi-Fi, a `xiaozhi:` device Bot, and four Bot tools.
- **Coordinator and contract owner:** Claude (this session). **Implementers:** relay end (SDK),
  Bot-tool end (SDK + Worker lists), app end (probe app). **Reviewer/integrator:** the coordinator.
- **Owning spec:** [xiaozhi-firmware.md](../../spec/device/v1/xiaozhi-firmware.md). Shared fixtures:
  `spec/device/v1/golden/xiaozhi-ota.jsonl` (spec oracle `spec/v1/tools/test_xiaozhi_firmware_golden.py`),
  `spec/bot/v1/golden/tool-catalog.phone.json` section `xiaozhiFirmware`,
  `spec/bot/v1/golden/tool-effects.phone.json` (four new `valid` vectors).
- **Producers/consumers:** the xiaozhi board (OTA client, unchanged) ↔ relay; relay ↔ upstream
  `api.tenclass.net` (unchanged); Bot runtime (Swift) ↔ Worker caller catalog and approval gate
  (TypeScript); probe app ↔ firmware builder page JS. Android: none (`target`, GAP-20).

## 2. Delta

| Item | Before → after |
| --- | --- |
| LAN listener | none for xiaozhi → DEBUG port 8781, private peers, explicit toggle (§2.1) |
| OTA response | upstream only → relayed, `firmware` replaced only while an image is staged for that MAC (§2.4) |
| device-Bot key space | link / gatt / lan / tonolink → adds `xiaozhi:<mac>` (§4); device-bot.md tables point to it |
| device-app tools | listed for every bound Bot → not listed for a `xiaozhi:` Bot |
| Bot tools | adds four device-bound tools, DEBUG only (§6) |
| builder pack | adds optional `manifest.sources_root`; builds may take overrides (§5) |
| UI | adds 「设置 › 小智固件（仅 DEBUG）」 (P09, regenerated page contract) |

Self-check: no second envelope; every new field is optional with a defined default; the board's
protocol is not changed; no name or number is reused.

## 3. Compatibility

| Producer → consumer | Behaviour |
| --- | --- |
| board (any xiaozhi version with `firmware{version,url}`) → relay | relayed unchanged unless an image is staged |
| relay → board | `offer` uses a strictly newer dotted version; `hold` never newer: no loop, no downgrade |
| new Worker → old app | tools absent (no host installed): the caller catalog hides them |
| old Worker → new app | the tools would be outside `AUTO_TOOLS`; Worker and app ship together in the bundle |
| old pack (no `sources_root`) → new app | tools report `no_editable_sources`; the reference build still works |
| persisted data | none |

Rollback: switch the relay off or set the board's OTA URL back; nothing on the board changes.

## 4. File ownership and acceptance

| End | Paths | Acceptance |
| --- | --- | --- |
| relay | `Sources/PhoneDSHBLE/Xiaozhi/**`, `Tests/PhoneDSHBLETests/XiaozhiOTATests.swift` | `swift test --filter XiaozhiOTA` runs every `xiaozhi-ota.jsonl` report/rewrite vector |
| Bot tools | `Sources/PhoneDSHBot/Xiaozhi/**`, `BotMCPRuntime.swift`, `Authz/BotToolEffects.swift`, `DeviceBot/DeviceBotBinding.swift`, `DeviceApp/WiringDeviceApp.swift`, `Tests/PhoneDSHBotTests/**`, `plugins/bot-runtime/src/{caller-catalog,approval-gate}.ts`, `plugins/tests/**` | `swift test --filter "Xiaozhi\|BotGoldenVector\|DeviceBot"`, key/name/description vectors, golden catalog section byte-compared; `npm test` in `plugins` |
| app | `examples/probe-app/FirmwareBuilder/**`, `FirmwareBuilderTests/**`, `PhoneDSHProbe/{FirmwareBuilderPage,XiaozhiFirmwarePage,DeviceBotRegistry,SettingsPage}.swift`, `PhoneDSHProbe/Bot/{XiaozhiFirmwareWiring,BotRuntimeComposition,DeviceAppWiring}.swift`, `scripts/firmware-pack/**` | `node --test FirmwareBuilderTests/` (override vectors), Xcode Debug build, device E2E (§8) |

Only the coordinator edits `spec/**` during the task (UI page contract regenerated at integration).

## Revisions

- r1 (this commit): frozen.
