<!-- SPDX-License-Identifier: MIT -->
# DEBUG control channel (DEV-01, developer tooling, not a product protocol)

ID: **DEV-01** (`debug-channel-v1`). Status: `implemented` (iOS DEBUG builds only). Owner: whoever edits
`examples/probe-app/PhoneDSHProbe/DebugChannel.swift`. Readers: `examples/probe-app/scripts/pdsh-debug.py`
and any other developer script. This is **not** one of the shipped wire protocols: it adds nothing to
`phone-dsh-v1`, host events, MCP, Link or the Bot tool surface, and no product component may depend on it.

## 1. Guarantees

- **DEBUG only.** `Sources/PhoneDSHLoopback/DebugChannelCodec.swift`, `DebugChannel.swift` and their call
  in `App.init()` are inside `#if DEBUG`. A Release build contains none of them (checked by a Release
  build and a symbol search; see docs/debug-channel.md).
- **Foreground only.** The TCP listener (port 47099) is created when the app becomes active and cancelled
  when it enters the background.
- **Token.** A fresh random 128-bit hex token per listener start. Every request must carry
  `X-PDSH-Debug-Token: <token>`; otherwise `401 {"error":"token"}`. The token is written to the DEBUG trace
  (`Documents/tonolink-voice.log`, line `debug-channel listening port=… token=…`) and to
  `Documents/debug-channel.json` `{port, token, started}`; the Mac reads it with `devicectl … copy from`.
- **Private peers only.** The peer address must be loopback, link-local, RFC 1918 IPv4, `::1`, `fe80::/10`
  or `fc00::/7` (this includes the CoreDevice tunnel address). Anything else gets `403 {"error":"address"}`
  before the token is looked at.
- No new dependency (Network.framework and the repo's own code only).

## 2. Wire

HTTP/1.1, one request per connection, `Connection: close`, JSON bodies, header ≤ 16 KiB, body ≤ 1 MiB.
Unknown route → `404` with the route list. Malformed request → `400`.

| Route | Purpose |
| --- | --- |
| `GET /info` | bundle id/version/build, app state, whether the Bot runtime is up, Worker bundle record |
| `GET /bots` | roster `{id,name,description,created_ms,device_key,main}`, `bindings` (`deviceBots.v1`), `intents` |
| `GET /devices` | BLE devices `{id,name,state,link_state,link_device_id,tools,granted_tools,rssi}` |
| `GET /deviceapps?device=` / `POST /deviceapps/act {device?,action:"open"\|"stop",name}` | the device-apps page's own model (`DeviceAppsPageModel` over the real user-origin Link path): rows `{name,title,detail,running}`, free space, phase; open/stop only, never delete (that confirmation is the user's tap) |
| `GET /ui/deviceapps.png?width=` | layout check: `DeviceAppsPage` over stub data (long title, duplicate titles, running apps) rendered with `ImageRenderer` as base64 PNG JSON; no device is touched (menus and some controls draw as placeholders in this renderer) |
| `POST /devices/connect {device}` | scan and connect a device by id or name |
| `GET /logs?name=voice\|status&lines=N` | tail of `tonolink-voice.log` / `chat-status.log` (token line removed) |
| `POST /bots/create {name,description?}` | a plain unbound Bot (for testing) |
| `POST /bots/delete {ids[],full?}` | batch profile delete (`BotProfileStore.deleteBots`); `full:true` runs `composition.deleteBot` per Bot |
| `POST /chat {prompt,bot?,wait?,approve?}` | admit a user turn to a Bot and wait; returns `state` (`done`, `awaiting_approval`, `timeout`), `calls[]` `{name,args,output,is_error}`, `final_text`; `approve:"allow"\|"deny"` resolves cards as they appear |
| `GET /turn?wait=S` | keep waiting for the last chat |
| `GET /approvals?bot=` | pending approval cards `{bot,row,detail}` |
| `POST /approve {bot,decision?,row?}` | resolve the pending card (`allow` once, or `deny`) |
| `GET\|POST /grants` | list, or `{device,tools[],enabled}` set, the Link tool grants |
| `POST /link {device,name,args?}` | one Link call as user origin (`callLinkTool`), e.g. `app.info` |

Outputs are truncated (args 1500, output 2500 characters). Responses are developer diagnostics: field
names may change without a version bump; a reader must ignore unknown fields.

## 3. Not allowed

No route may bypass a product approval for an agent-origin action: `/approve` uses the same
`BotChatModel.decide` the card button uses, and `/link` runs as the **user** origin exactly like the device
panel. `/bots/delete` deletes only what the caller names. The channel never exposes API keys, the model
credential or Keychain values.

## 4. Compatibility and rollback

New surface; nothing reads it but developer scripts. Removing the file removes the surface. Old Debug
builds simply lack the routes (`404`).

## 5. Verification

- Unit: `Tests/PhoneDSHLoopbackTests/DebugChannelCodecTests.swift` runs the real decoder, token check and
  address check (missing/wrong/short token, empty server token, private and public address tables,
  framing).
- Device: the end-to-end timings in docs/debug-channel.md.
