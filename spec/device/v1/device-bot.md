<!-- SPDX-License-Identifier: MIT -->
# Device Bot v1 (`device-bot-v1`)

Status: Link devices and the TonoLink board are `implemented` on iOS in the earlier form of
[PC-20261114-device-bot](../../../docs/protocol-changes/PC-20261114-device-bot.md); the rules
below that tighten that behaviour (§3 key space, §4 trigger, §5 name and description, §6
idempotent creation) are `implemented` on iOS (PC-20261117-device-bot-contract). The standard GATT
and LAN triggers are `implemented` on iOS at the call sites below (unit-tested on the real decision
functions; no real GATT peripheral or LAN device run). Android is `target` for every class and stays blocked by GAP-20 and the Android half of
[device-panel](device-panel.md). No real-device run covers GATT or LAN.
Owner: P07 (device trigger, key, text); the persisted map is P18.

One connected and trusted device gets one ordinary Bot. The binding is a phone-local map; the
shared Bot profile and rows are unchanged (P27), and the desktop sees an ordinary Bot.

## 1. What this is not

- Not a sandbox. A device Bot receives no authority beyond what any Bot has. Device grants stay
  App-wide ([ble-link.md](ble-link.md) rule 6, [lan-mcp.md](lan-mcp.md)); scoping tools per device
  is a separate P26 change.
- Not an identity. A key names a device for this phone only. Link `device_id` is self-reported,
  a CoreBluetooth UUID is a per-App handle, a LAN host is a name the user granted; none is
  cryptographic ([ble-identity.md](ble-identity.md)).
- Not a trust decision. Scanning, advertising, discovery and a bare connection create nothing.

## 2. Persisted state (P18)

| UserDefaults key | Value |
| --- | --- |
| `deviceBots.v1` | `{ <key>: <Bot id> }` (string to string) |
| `deviceBots.intents.v1` | `{ <key>: <creation id> }` (string to lowercase UUID) |

Both maps are written whole and synchronized before the call that depends on them returns: a
killed App must not forget a binding or an intent. A reader keeps every entry it does not
understand (unknown key prefix, extra keys) and writes it back unchanged; an older build that
rewrites the map therefore must not drop newer entries. A binding whose Bot id is not in the Bot
roster is treated as unbound.

## 3. Key space

A key is derived once from the device class and is never edited afterwards.

| Class | Key | Notes |
| --- | --- | --- |
| Link device | lowercase `device_id` as listed by `tools/list`, **no prefix** | Existing keys; a non-empty string with no `:`. |
| standard GATT | `gatt:` + lowercase CoreBluetooth peripheral UUID | UUID in 8-4-4-4-12 form. |
| LAN MCP | `lan:` + canonical hostname `H` of the granted URL, plus `:<port>` unless the port is 443 | `H` is already in the canonical form of [lan-mcp.md](lan-mcp.md); a non-canonical host is rejected, not repaired. Port 1…65535. Changing host or port is an endpoint change and therefore a new key. |
| TonoLink board (legacy) | `tonolink:` + lowercase BLE name | Existing key for the board's voice link; kept readable. Never created for a board that already has a Link key. |

An input that does not fit its row has no key and creates nothing. Two devices never share a key;
one device may hold a legacy key and a Link key, see §6 alias.

## 4. Trigger

A Bot may be created only by one of these events, each after the device's own admission:

| Class | Event |
| --- | --- |
| Link device | the Link handshake and identity step have passed and `tools/list` has returned (the user's connection of a board is the trust decision of ble-link rule 6) |
| TonoLink board voice link | the voice link is up (legacy key, until `tools/list` gives a Link key) |
| standard GATT | the user turns on a read grant or an alert grant for that peripheral |
| LAN MCP | the user saved the exact-URL grant and the credential for that endpoint |

Revoking a grant, disconnecting, losing Bluetooth or forgetting the device never creates, hides or
deletes a Bot.

## 5. Name and description

The Bot's name and description are produced from fixed templates. Device-reported text is
untrusted and the description reaches the model, so it carries no free text from the device.

**Name** (device name or fixed text → name):

1. Normalize to NFC.
2. Delete format characters (Unicode `Cf`); turn control characters, line and paragraph
   separators and space separators (`Cc`, `Zl`, `Zp`, `Zs`) into U+0020.
3. Collapse runs of U+0020 into one, trim both ends.
4. Keep at most 60 Unicode scalar values, then trim a trailing space.
5. An empty result is `设备助手`, and so is a result that is a technical id (revision v1.1): it
   starts with `PDSH-` (ASCII, case-insensitive), or is 4 or more ASCII hex digits only, or is
   three or more hex pairs joined by `:` or `-` (`AA:BB:CC`). Anything else, including `PDSH`,
   `abc` and `灯1234`, is kept. The TonoLink board's name is the fixed `手机助手`.
6. If another Bot in the roster already has exactly that name, append ` 2`, ` 3`… (smallest
   free number ≥ 2); the base is shortened so the whole name stays within 60 scalars.

**Description**, by class:

| Class | Text |
| --- | --- |
| board | `通过小智 Link 帮你操作这台 iPhone：打开 App、点按、输入、看屏幕，也能调板子的灯效。对板子说「你好小智」就会找我。` |
| Link, device-app capable (revision v1.1) | `管理一台设备，可以帮你写小应用装到设备上（比如计时器、计数器）。装之前会先问你。` Chosen only when `tools/list` contains all eight of `app.info`, `app.begin`, `app.put`, `app.abort`, `app.commit`, `app.run`, `app.stop`, `app.remove` (exact, case-sensitive names). Fixed text, no tool names. |
| Link, other | `管理一台通过 Link 连接的设备。` and, when at least one tool qualifies, `可用工具：a、b。` |
| standard GATT | `管理一台标准蓝牙设备。` and, when at least one profile is granted, `已授权：电池、温度。` |
| LAN | `管理一台局域网设备（H）。`; a host that does not match `^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$` is omitted with its parentheses |

A Link tool name qualifies when it matches `^[a-z0-9_.-]{1,64}$`; duplicates are dropped, order is
kept, at most 8 are listed. GATT profile labels in this fixed order: `battery` 电池,
`temperature` 温度, `humidity` 湿度, `manufacturer` 厂商, `model` 型号, `alert` 提醒; other
profile names are ignored.

Revision v1.1 changes text only. Keys, `decide` and `complete` are unchanged; a Bot that already
exists keeps its name and description (nothing renames or re-describes it).

## 6. Idempotent creation and lifecycle

The decision function `decide(state, key, new_creation_id, alias?)` over the state
`{bindings, intents, roster, created}` (`created` is creation id → Bot id from the durable
`ui.system_event{event:"teammate.created"}` rows) returns one action:

1. `bindings[key]` is in the roster → `none`.
2. A stale binding (Bot not in the roster) is dropped first.
3. `alias` is given, is a key of `bindings` and its Bot is in the roster, and `key` has no live
   binding → `bind` `key` to that Bot (the board's move from a legacy key to its Link key; the old
   entry stays).
4. `intents[key] = c` exists: if `created[c]` is in the roster → `bind` to it and drop the
   intent; otherwise → `create` with the same `c` (the earlier attempt died before or after the
   Bot existed; the creation id keeps it from being made twice).
5. Otherwise record `intents[key] = new_creation_id` **before** creating → `create`.

`complete(state, key, bot)` after a successful create sets `bindings[key] = bot` and removes
`intents[key]`. The creation passes author kind `device`, the key and the creation id to the
audited create path, so `teammate.created` carries them; the Bot profile gets no new field.

**Names and descriptions never identify a Bot.** A Bot with the same name and description as a
device's template is not that device's Bot.

Consequences, each exercised by a vector:

- Delete the Bot → next trigger creates a new one and a new binding.
- Forget the device → binding and Bot stay; the same key later finds its Bot again.
- New key for the same hardware (new Link `device_id`, new host) → a new Bot.
- Two devices with the same name → two Bots, the second with a numbered name.
- A lost map entry can leave one extra Bot (an intent without a created event cannot be told from
  an earlier Bot); it is never bound to someone else's Bot.

## 7. Platform status

| End | State |
| --- | --- |
| iOS | Link, board, standard GATT and LAN: `implemented`; GATT/LAN not run on a real peripheral or LAN device |
| Android | `target`; blocked by GAP-20 and device-panel's Android half; no platform branch may stand in |
| Desktop | no change; sees an ordinary Bot |

## 8. Fixtures and checkers

| File | Purpose |
| --- | --- |
| [schema/device-bot-binding.schema.json](schema/device-bot-binding.schema.json) | the closed shape of one vector |
| [golden/device-bot-binding.jsonl](golden/device-bot-binding.jsonl) | key, name, description, `decide` and `complete` vectors, valid and invalid |
| [spec/v1/tools/test_device_bot_binding_golden.py](../../v1/tools/test_device_bot_binding_golden.py) | pins the file hash, validates the schema, replays every vector through a reference oracle |

The oracle is a spec checker, not runtime conformance. The iOS registry must be moved into a
library target and run the same file through its real functions; Android must do the same when it
implements this file.

## 9. iOS trigger call sites and recorded decisions

- **Standard GATT:** the trigger fires only from the user's off→on toggle of a read or alert grant in
  the BLE device page (`BLEDeviceStore.userGrant`, decision `GattBotTrigger.decide`), compared after
  the grant ran. A bare connection, scan, trust restore or the `trustConnectedDevices` default never
  fires. A Link device or the TonoLink board is not a GATT class device. A read grant on a device with
  no discovered profile still fires, with an empty profile list. Known edge: a toggle made before the
  Link identity or `tools/list` arrives can create a `gatt:` Bot first and a Link Bot later (two keys
  for one device; recorded, not prevented).
- **LAN MCP:** the trigger fires when the user saves the grant and the `Authorization` credential for
  an endpoint (MCP settings save path, decision `LANGrantTrigger.newlySaved`). Decision: only
  `https://H[:port]/mcp` with a canonical host, no userinfo, query or fragment counts; `http` never
  does. lan-mcp.md has no rule that separates a LAN host from a public one, so any such HTTPS endpoint
  counts. Narrowing to private or `.local` hosts is a separate contract change. Re-saving an unchanged
  endpoint does not fire; adding the credential later, or changing host or port, does.
