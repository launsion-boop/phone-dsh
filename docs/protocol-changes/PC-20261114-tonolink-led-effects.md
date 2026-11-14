# TonoLink LED effects for the voice task phases, set from the device panel

```yaml
change: PC-20261114-tonolink-led-effects
contracts: [P07]
status: implemented
breaking: false
version_decision: Additive. Three new Link tools advertised only by firmware that has them, one new ctrl verb (`<seq> fx <phase>`) older firmware refuses, an additive `phase` member in light.get/light.set results.
base: origin/main 06a80094
contract_revision: spec/device/v1/tonolink-board.md §4.3 @ this branch
```

Protocol impact: P07. P07 — the TonoLink board boundary gains §4.3: the ctrl `fx` verb (phone → board),
the Link tools `light.phase`, `light.effect.set`, `light.effect.get`, and the `phase` member in light results.

## Trigger → current → expected

- Trigger: the user asked for "cool" effects on the board's 6 LEDs for wake, task start, task running,
  task report and task done, settable from the mini program (device panel).
- Current: the LEDs only had on/off (`light.set`) and a console demo chase.
- Expected: each phase has its own animated effect; the board lights `wake` itself; the phone's voice
  turn moves through the other phases; the device panel edits and previews each phase's style.

## Ends

| End | Change |
| --- | --- |
| Firmware (`tonolink-m21-r4-firmware`, branch `feat/led-effects`) | `main/fx/fx_render.{c,h}` pure renderer (8 effects, power cap), `main/fx/fx.{c,h}` engine (phase timing, NVS styles, 25 ms frames), Link tools, `fx` ctrl verb, wake → `wake` phase, console `fx` |
| Phone BLE library | `TonoLinkVoiceCommand.fx`, `TonoLinkLightPhase`; shared vectors `fx_commands` |
| App voice turn | `TonoLinkVoiceHost` sends start / running / report / done / idle through a serial queue; `listen` waits for it |
| Device panel | none: the panel renders the new tools from their `inputSchema` (pickers and integer sliders) |

## Compatibility

| Pair | Behaviour |
| --- | --- |
| New phone → old firmware | `fx` is refused (`ack err`), logged and ignored; the tools are not advertised, so the panel does not show them |
| Old phone → new firmware | wake still lights by itself; the other phases never come, so the wake effect ends after 15 s |
| Rollback of the firmware | the NVS key `fx/styles1` stays unread |
| Old receipts / journal | unchanged |

## Commands → results (2026-11-14)

- Firmware `bash host_tests/run.sh --filter fx_render` → PASS (8 tests: names, distinct defaults, bounds, phase timing, power cap over every effect, animation, brightness, comet shape); full `host_tests/run.sh` → 34 passed, 0 failed, 7 skipped (need ESP-IDF)
- galic `idf.py build` (ESP-IDF v6.1, esp32s3) → PASS, 0 warnings, `agent_s3.bin` 2,104,256 B
- Device `TonoLinkLightDeviceTests/testUSBOTAOfTheBundledImage` (iPhone 00008160-00023D1C2240000A, iOS 27.2, board PhoneAgent-7356) → PASS: USB upload, reboot, confirmed `0.1.0-m21` in `ota_1` (`valid`), elf `bac7532c…`
- Device `testEffectsOverLinkToolsAndTheCtrlLine` → PASS: `tools/list` advertises and the app grants the three tools; `light.phase` reports each of the six phases; `light.effect.set` saved and `light.effect.get` read back a change (restored afterwards); ctrl `fx task_start` → `ok`, `fx disco` → `err range`
- Device `testEffectsPanel` → PASS: the descriptor (6 phase previews, the style editor, read-out, white light on/off) is adopted by the real evaluator; a preview call completes
- `swift test --filter TonoLinkVoice` → PASS (6, including the shared `fx_commands`); `phone-cross-tree` → PASS

## Not verified

- **What the LEDs look like.** Nothing here observed the light: the tests prove the phase/style state the board reports, not the colours. Someone has to look at the board.
- A real voice turn driving start → running → report → done (the phone code is compiled and in the app, not exercised end to end).
- Power draw at full brightness on the iPhone's USB supply.
- The style editor in the panel shows raw argument names (`brightness`, `effect`, `hue`, `phase`, `speed`) and hue as a number; labels would need a descriptor-level change (contract).

## Revision 2 (2026-11-14): Chinese labels and a Send that works

User report on the phone: the style editor's Send stayed grey, and nothing was in Chinese.

- Cause of the grey Send: all five arguments of `light.effect.set` were required and the panel starts every
  editor unset (device-panel.md §2), so three sliders also had to be moved first.
- **Firmware:** only `phase` and `style` are required; `color` (named: 红 橙 黄 绿 青 蓝 紫 粉 白), `brightness`
  and `speed` are optional and keep their saved values; `hue` (0–359, 360 = white) is still accepted. Enum values
  and `title`s are Chinese; English names stay accepted (agent, ctrl line). The read-out has one Chinese row per
  phase. `tools/list` is 2,320 bytes (limit 4,096).
- **Panel contract (P07, device-panel.md §2, fixtures device-panel-v1.1):** a property may carry `title`
  (1–20 scalars, no C0/DEL) used as the editor label; an invalid title makes the property unsupported; presets
  ignore it. Required editors come first, then optional; each group by code point. Vectors: mapping 36 → 44
  (titles valid/invalid, required-first ordering), descriptor cases 59 → 62 (presets and editors on titled tools).
  Old hosts treat a titled property as unsupported (a required one makes the tool agent-only), so firmware with
  titles needs this app; the board is not released with titles to older apps.

Commands → results (revision 2):
- `python3 -m unittest discover -s spec/v1/tools -p 'test_device_panel_golden.py'` → PASS (6; new digests)
- `swift test --filter 'DevicePanel|TonoLinkVoice'` → PASS (29, including order/title mutations)
- firmware `host_tests/run.sh` → 34 passed, 0 failed (renderer 10: Chinese names, colours, white)
- galic build → PASS, 2,105,392 B; USB OTA → confirmed `ota_0` (`valid`)
- Device `testEffectsOverLinkToolsAndTheCtrlLine` → PASS (Chinese phases; a set with colour 粉 and no brightness kept the saved brightness)
- Device `testEffectsPanel` → PASS: titles 阶段/效果/颜色/亮度 %/速度, Send inactive before and **active after choosing only 阶段 and 效果**, the editor's Send saved a style (restored afterwards)
