<!-- SPDX-License-Identifier: MIT -->
# Xiaozhi firmware Bot v1 (`xiaozhi-firmware-v1`)

Status: `implemented` on iOS, **DEBUG builds only** (PC-20261118-xiaozhi-firmware-bot). The relay,
rewrite, report parser, device Bot key/text, the four Bot tools and the on-phone build with source
overrides are unit- and golden-tested and the probe app builds and installs on device; no real board
has fetched an offered image over the relay yet (the board's OTA URL must be repointed at the phone
first). Android is `target` (GAP-20). Android is
`target` (GAP-20). Owners: P07 (OTA relay, device record, device-Bot key and trigger, §2–§5),
P26 (Bot tools, §6), P18 (none: nothing in this contract is persisted in UserDefaults).

A phone user connects a board that runs the upstream xiaozhi firmware
([78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32)). The phone gets one device Bot for it.
That Bot can export the firmware sources, edit them, build the firmware on the phone with the
firmware builder pack, and push the image to the board over Wi-Fi through xiaozhi's own OTA check.
No cable, no computer, and no change to the xiaozhi firmware are needed after the board's OTA URL
points at the phone.

## 1. Non-goals and trust

- **No authentication of the board.** xiaozhi's OTA check carries `Device-Id` (the Wi-Fi MAC) and
  `Client-Id` (a board UUID). Both are self-reported. Neither is an identity; the MAC is used only
  as a phone-local key (§4), like `device-bot.md` §1.
- **The relay is not a gateway.** It forwards one fixed upstream URL (§2.2). It is not reachable
  from the Worker, it is not an egress route for Bots, and Worker egress rules do not apply to it.
- **The served image is public on the Wi-Fi while it is staged.** Anyone on the same Wi-Fi who
  knows the URL can download it, as with the TonoLink relay (`tonolink-board.md` §5). Release
  builds contain none of this.
- **No board-side change.** Firmware is delivered only through xiaozhi's existing OTA response
  field `firmware {version, url}`. The phone never asks the board to downgrade, never edits NVS and
  never calls MCP tools on the board.

## 2. OTA relay (P07)

### 2.1 Listener

- DEBUG only. Off by default. It listens only while the user has switched it on in
  「设置 › 小智固件（仅 DEBUG）」 and the app is running; leaving the page does not stop it.
- TCP port **8781**, every non-cellular interface (`prohibitedInterfaceTypes = [.cellular]`).
- Peers must be private addresses (RFC 1918, link-local, ULA; the `DebugChannelCodec.isPrivate`
  rule). Any other peer gets `403` and is not recorded.
- One request per connection; the request head is at most 16 KiB and the body at most 64 KiB
  (larger: `413`). `Transfer-Encoding` is rejected (`400`); a body needs `Content-Length`.
  Every response has `Connection: close` and `Cache-Control: no-store`.
- The page shows the OTA URL to type into the board:
  `http://<Wi-Fi IPv4>:8781/xiaozhi/ota/`. Without a Wi-Fi IPv4 the page says so and shows no URL.

### 2.2 Routes

| Method and path | Behaviour |
| --- | --- |
| `GET` or `POST` `/xiaozhi/ota/` (exact; the trailing `/` is required) | §2.3 |
| `GET` `/xiaozhi/firmware/<sha>.bin`, `<sha>` = 64 lowercase hex | §2.5 |
| anything else | `404`, empty body |

### 2.3 Version check relay

1. Parse the device report (§3) from the request. A body that is present but is not a JSON object
   gives `400` and no forwarding.
2. Forward the same method and body to the upstream `https://api.tenclass.net/xiaozhi/ota/`,
   with exactly these request headers copied when present (case-insensitive names, values
   unchanged): `Device-Id`, `Client-Id`, `Serial-Number`, `Activation-Version`, `User-Agent`,
   `Accept-Language`, `Authorization`, `Content-Type`. No other header is copied. Timeout 20 s.
3. Upstream unreachable, timed out, or a TLS failure: reply `502` with an empty body. The device
   record is still updated (§3).
4. Otherwise reply with the upstream status and the body from the rewrite (§2.4); `Content-Type`
   is the upstream's, or `application/json` when the upstream sent none.

### 2.4 Rewrite (`XiaozhiOTARewrite.apply`)

Inputs: the upstream status, the upstream body bytes, the device report, the staged image for that
device (or none), and the image base URL `http://<Wi-Fi IPv4>:8781`. Output: the body bytes and a
decision. Rules, first match wins:

| # | Condition | Decision | Body |
| --- | --- | --- | --- |
| 1 | no staged image for the report's MAC | `passthrough` | upstream bytes unchanged |
| 2 | upstream status is not 200, or the body is not a JSON object | `passthrough` | unchanged |
| 3 | the report has no parsable `application.version` (dot-separated non-negative integers) | `passthrough` | unchanged |
| 4 | the report's `application.elf_sha256` equals the staged ELF SHA-256 | `hold` | the object with `firmware` set to `{"version": <reported version>, "url": ""}` |
| 5 | otherwise | `offer` | the object with `firmware` set to `{"version": <reported version> + ".1", "url": <base>/xiaozhi/firmware/<staged image sha256>.bin}` |

- Every other member of the upstream object is kept, in its order. An existing `firmware` member
  is replaced in place; a missing one is appended last.
- `hold` stops an official OTA from replacing a staged build that is already running, and stops an
  endless upgrade loop: the upstream firmware version is never compared and never offered while an
  image is staged for that device. xiaozhi upgrades only when the offered version is newer
  (`Ota::IsNewVersionAvailable`); `<v>` is never newer than itself, and `<v>.1` is always newer
  than `<v>`.
- After an `offer` the board downloads, writes, reboots and checks in again; its report then has
  the staged ELF SHA-256 (§3), which gives `hold`. The board keeps reporting the upstream version
  string, because the pack fixes the app descriptor (§6.4).
- The shared vectors are `golden/xiaozhi-ota.jsonl` (`kind: "rewrite"`). Body equality is JSON
  value equality plus member order.

### 2.5 Firmware download

`GET /xiaozhi/firmware/<sha>.bin` returns the staged image whose image SHA-256 is `<sha>` with
`200`, `Content-Type: application/octet-stream` and `Content-Length`. No staged image with that
digest: `404`. Range requests are not supported (the whole image is returned).

The listener writes the head and then the body in 32 KiB chunks. The bytes on the wire are exactly
the single response above; chunking only lets the relay count, per MAC, the body bytes the local
TCP stack has accepted (`XiaozhiDownloads`: `sending`, `complete` or `aborted`, newest download
wins). That count is for the progress UI (§9) only: it never changes a response, a rewrite decision
or a device record, no Bot tool returns it, and "complete" is not proof the board wrote the image —
only the next check-in on the staged ELF (§2.4 `hold`) is.

## 3. Device record (P07)

From each version check the relay records, in memory, per MAC:

| Field | Source | Rule |
| --- | --- | --- |
| `mac` | header `Device-Id` | lowercase `aa:bb:cc:dd:ee:ff`; anything else: the check is relayed but not recorded |
| `version` | body `application.version` | string or null |
| `elfSha256` | body `application.elf_sha256` | 64 lowercase hex, else null |
| `boardType` | body `board.type` | string or null; shown in the UI, never used in Bot text |
| `lastSeen` | relay clock | |
| `lastDecision` | §2.4 | `passthrough`, `hold`, `offer` or `upstream_failed` |

Records are lost when the app quits. `golden/xiaozhi-ota.jsonl` `kind: "report"` vectors pin the
parsing.

## 4. Device Bot (P07; extends device-bot.md §3–§5)

- **Key:** `xiaozhi:` + the recorded MAC. Example `xiaozhi:98:c3:77:f4:ff:38`. Vectors: `kind: "key"`.
- **Trigger:** the user taps 「信任并创建 Bot」 on a recorded device in the 小智固件 page. A version
  check alone creates nothing. Creation uses `DeviceBotBinder.ensure` (idempotent, device-bot.md §6).
- **Name:** raw name `小智 ` + the last two MAC octets in upper case without the colon
  (`小智 FF38`), then device-bot.md §5 name rules. Vectors: `kind: "name"`.
- **Description:** exactly `管理一台小智设备（<MAC>）：可以导出和修改固件源码、在这台 iPhone 上编译，并通过 Wi-Fi 刷入新固件。刷入前会先问你。`
  No device-supplied text (board type, versions) enters it. Vectors: `kind: "description"`.
- A Bot bound to a `xiaozhi:` key is a device-bound Bot for §6 only. The device-app tools
  (`device-app.md` §7) are **not** listed for it.

## 5. Firmware builder inputs (P07; probe app)

- The pack's `manifest.json` gains the optional member `sources_root`: the absolute path, as the
  pack sees it, of the directory whose files the Bot may edit (for the xiaozhi pack
  `/root/xiaozhi-passport/xiaozhi-esp32/main`). A pack without it has no editable sources and the
  §6 tools report `no_editable_sources`.
- **Editable files** are the `project.bin` files whose path starts with `sources_root + "/"`.
- **Overrides:** a build may receive a map from editable path to new bytes. The builder writes each
  override into the in-memory file system after loading `project.bin` and before the first compile
  job. An override for a path that is not editable is a build error (`not_editable`), not ignored.
  Adding or deleting files is not supported; a deleted export file means "use the pack's version".
- Without overrides the build is the pack's reference build (byte-identical, firmware builder
  README).

## 6. Bot tools (P26)

Listed in the all-callers `tools/list` whenever the app installed the xiaozhi firmware host (DEBUG
builds with a staged pack that has `sources_root`), and in the per-caller `tools/list` only for a
Bot bound to a `xiaozhi:` key; the Worker caller catalog hides them for an identified caller whose
catalog lacks them, like the device-app tools. They are absent from the static catalog and p0/p1. Names, descriptions and
input schemas are frozen in the `xiaozhiFirmware` section of `spec/bot/v1/golden/tool-catalog.phone.json`;
classifications in `tool-effects.phone.json`. All are App-owned tools (Worker `AUTO_TOOLS`).

### 6.1 `XiaozhiSourceExport {}`

Copies every editable file into the calling Bot's workspace through the workspace import RPCs
(`phone/importBegin|Write|Commit`, P13), target directory the Bot root, entry name `xiaozhi-src`.
Paths below the export root are the path relative to `sources_root`.
Success: `{ok:true, directory, files, bytes, pack:{project, target}}` where `directory` is the
absolute workspace path the import committed (`…/imports/xiaozhi-src[-N]`). Effect: `write`/`auto`,
operation `device.xiaozhi.export`.

### 6.2 `XiaozhiFirmwareBuild {directory?}`

`directory`: an absolute workspace path previously returned by §6.1 (string, optional). With it,
every regular file below it whose relative path is an editable path and whose bytes differ from the
pack becomes an override (§5); a file whose relative path is not editable is listed in `ignored`.
Without it, the reference build runs. The host reads the files from the materialized workspace
mirror, so a write the model made in the same turn may not be visible yet; `changed` lists what
the build used.
Starts a build unless one is running (then `{ok:false, code:"busy", jobId}`), waits up to 100 s,
and returns either the finished job or `state:"running"`:
`{ok:true, jobId, state:"running"|"done"|"failed", changed:[path], ignored:[path], error?,
image?:{bytes, sha256, elfSha256, version, matchesReference}}`.
Effect: `read`/`auto`, operation `device.xiaozhi.build`.

### 6.3 `XiaozhiFirmwareStatus {jobId?}`

Returns the job (latest when omitted), the bound device's record (§3) and its staged image:
`{ok:true, job?:{…as §6.2…}, device:{mac, seen, version?, elfSha256?, lastSeen?, lastDecision?},
staged?:{sha256, elfSha256, url}, relay:{on, otaURL?}}`. Effect: `read`/`auto`, operation
`device.xiaozhi.status`.

### 6.4 `XiaozhiFirmwareFlash {elfSha256}`

`elfSha256`: 64 lowercase hex, the ELF SHA-256 of a finished build in this app session. Asks for
approval first (once only, no 「始终允许」; label 「给小智刷入固件」, detail names the MAC and the
first 12 hex of the ELF SHA-256). After approval it stages that image for the bound device (§2.4),
replacing any earlier staged image for it. It does not reboot the board: xiaozhi checks for an
update at boot, so the result tells the user to restart the board. Fails with `relay_off` when the
relay is not listening, `no_build` when no finished build has that ELF SHA-256.
Success: `{ok:true, staged:{sha256, elfSha256, url}, device:{mac}, next:"重启小智（按复位键或断电重开），它开机检查更新时会下载并刷入；完成后用 XiaozhiFirmwareStatus 确认 elfSha256 一致。"}`.
Effect: `destructive`/`ask`, operation `device.xiaozhi.flash`.

### 6.5 Errors

`{ok:false, error:{code, message}}` with `code` one of `no_editable_sources`, `not_editable`,
`busy`, `no_build`, `relay_off`, `device_not_seen`, `build_failed`, `export_failed`,
`approval_denied`, `invalid_arguments`.

## 7. Interfaces between the ends (iOS)

| End | Path | Provides |
| --- | --- | --- |
| relay (SDK) | `Sources/PhoneDSHBLE/Xiaozhi/` | `XiaozhiDeviceReport.parse(headers:body:)`, `XiaozhiOTARewrite.apply(...)`, `XiaozhiOTARelayServer` (NWListener, §2), `XiaozhiStagedImages` |
| Bot tools (SDK) | `Sources/PhoneDSHBot/Xiaozhi/`, `BotMCPRuntime` slot `setXiaozhiFirmwareTools(_:)`, `DeviceBotKey.xiaozhi(mac:)`, `DeviceBotText` | `XiaozhiFirmwareToolHost` (closures injected by the app) |
| app (probe) | `FirmwareBuilder/`, `FirmwareBuilderPage.swift`, `XiaozhiFirmwarePage.swift`, `Bot/XiaozhiFirmwareWiring.swift`, `DeviceBotRegistry.swift` | build with overrides, source export, page, wiring |

## 9. Progress UI (P09; probe app, DEBUG)

Derived, never sent anywhere. Inputs: the staging time of the device's image (§6.4), the device
record (§3), the latest download (§2.5) and the builder's compile counters.

- **Build:** preparing → compiling `done/total` → linking, with the elapsed time; then
  finished (image size, first 8 hex of the ELF SHA-256) or failed (the job error).
- **Flash**, from the staging time: `waitingForReboot` (no check-in since staging) → `offered`
  (a check-in got `offer`) → `downloading` (bytes/total) → `installing` (all bytes sent, no check-in
  since) → `done` (a check-in after staging reports the staged ELF). `stalled`: no bytes for 20 s.
  `failed`: the download aborted with no later `offer`, or a check-in after a complete download
  reports another ELF.
- **Where:** the 「小智固件」 page (build in 「固件源码与构建」, flash per device row), and a strip
  directly above the activity band in the chat of a Bot bound to a `xiaozhi:` key (id
  `bot.xiaozhi.progress`). The strip shows a running build first, else an active flash, else a build
  finished in the last 2 minutes until its image is staged, else a flash done in the last 2 minutes or
  failed in the last 10. It can be closed (`bot.xiaozhi.progress.close`) only when nothing is in
  progress. Other Bots' pages are unchanged.

## Revisions (owning spec)

- r3 (PC-20261119-xiaozhi-progress): §2.5 chunked send and download count; §9 progress UI. No wire,
  tool, schema or golden change.

- r2 (this commit): §6 lists the four tools in the all-callers `tools/list` when the host is
  installed, hidden per caller, matching how the Worker registers and gates `mcp__phone__*` tools
  (device-app precedent). r1 said "absent from the all-callers list", which left them unregisterable.

## 8. Verification

`golden/xiaozhi-ota.jsonl` runs through the spec oracle (`spec/v1/tools/test_xiaozhi_firmware_golden.py`)
and through the real Swift functions (`Tests/PhoneDSHBLETests/XiaozhiOTATests.swift`,
`Tests/PhoneDSHBotTests/Xiaozhi/`). End to end: a board on the same Wi-Fi with its OTA URL set to
the relay checks in, a device Bot is created, a source edit is built on the phone, flashed after
approval and reported back with the new ELF SHA-256.
