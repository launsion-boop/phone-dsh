<!-- SPDX-License-Identifier: MIT -->
# Device app install v1 (`device-app-v1`)

Status: `target`. Nothing here is implemented on any end; no real-device run exists (`device-app-v1.5` adds the
Bot tools `DeviceAppList` and `DeviceAppRemove`, §7, §8.2, §12). The reference
device is a MicroPython board (FoloToy AI Passport) running the `link_peripheral` role of
[ble-link.md](ble-link.md); the host is the iPhone App. Android stays `target` (GAP-20).
Owner: P07 (tool surface, limits, admission). The Bot host tools that call it are P26.
Change record: [PC-20261117-device-app-push](../../../docs/protocol-changes/PC-20261117-device-app-push.md).

A device Bot ([device-bot.md](device-bot.md)) may write a small program, the user confirms it on the
phone, and the phone installs it on that device through the **unchanged** Link wire: ordinary
tools advertised in `tools/list`, one JSON request of at most 4096 bytes each. The program runs on
the device, never on the phone ([device-panel.md](device-panel.md) §1: the host executes no model- or
device-provided code).

## 1. Non-goals and trust

- No Link wire, opcode, capability bit or HELLO field changes. Old phones see ordinary tools.
- No signing. A bundle has integrity (sha256), not authenticity. The trust boundary is the Link
  pairing and the user's confirmation of each install; sandboxing is defence in depth, not a promise.
- Not for exclusive-mode apps (they reboot and drop the Link): `exclusive` is rejected in v1.
- Not a remote shell: no `exec`, no raw file write, no read of device settings.

## 2. Limits (v1)

| Limit | Value |
| --- | --- |
| files per app | 1–8; `main.py` and `app.json` are required |
| bytes per file / per app | ≤ 12288 / ≤ 24576 (a larger source costs several times its size in compile heap on a no-PSRAM board) |
| raw bytes per `app.put` | ≤ 2048 (base64 in `data`, so one request stays far below 4096) |
| session idle timeout | 120 s, then the device aborts it |
| sessions at once | 1 |
| app name | `^[a-z][a-z0-9_]{0,23}$` |
| file path | relative, 1–3 segments of `[A-Za-z0-9_-]` with an optional extension, total ≤ 64 characters, no leading `.`; extension `.py` or `.json` only |
| title (manifest) | 1–20 Unicode scalars, no control or format characters |
| UI name | the phone calls these "设备应用"; "小程序" already means the declarative panel of [device-panel.md](device-panel.md) |

## 3. The manifest `app.json`

Closed object: `name`, `title`, `version` (integer ≥ 1), `perms` (array of distinct strings from
`audio`, `mic`, `battery`; may be empty). Any other member, `exclusive`, or a `name` that differs
from the one in `app.begin` is invalid. `lcd`, `keys` and `ui` need no permission. Network, storage
writes, BLE and settings are not available to a v1 app.

## 4. Manifest digest

`digest = sha256` over the UTF-8 text made of one line per file, sorted ascending by the path's
UTF-8 bytes: `<path>\t<size>\t<sha256 lowercase hex>\n`. The phone shows the first 8 hex characters
and the file list to the user; the device recomputes it at `app.commit`.

## 5. Tools

All results are one JSON object with `ok` boolean; failures carry `code` (§8) and a short `message`
that is untrusted display text. The device advertises these names and `inputSchema`s in `tools/list`
and `app.info` returns `"protocol":"device-app-v1"`; a device without them is not an install target.

| Tool | Arguments | Result on success | Receipt class |
| --- | --- | --- | --- |
| `app.info` | `{}` | `protocol`, `apps:[{name,title,version,digest,running}]`, `free_bytes`, `free_mem`, `limits:{files,file_bytes,app_bytes,chunk_max,idle_s}` (§2) | none |
| `app.begin` | `name`, `files:[{path,size,sha256}]` | `session` (`^[0-9a-f]{8}$`), `chunk_max` (≤ 2048), `next:{path:0…}` | staging |
| `app.put` | `session`, `path`, `offset`, `data` (base64) | `next_offset` for that file | staging |
| `app.abort` | `session` | `{}` | staging |
| `app.commit` | `session`, `digest` | `name`, `digest` | durable |
| `app.run` | `name` | `{}` (the program starts after the reply) | durable |
| `app.stop` | `{}` | `{}` | durable |
| `app.remove` | `name` | `{}` | durable |

**Staging** tools write only to a staging area (RAM or `/apps/.stage/<session>/`), take **no**
durable Link receipt, and never touch an installed app. Because a lost reply is then
indistinguishable from "no record", they are made safe to repeat by their own rules in §6, not by the
Link receipt. **Durable** tools follow the Link receipt, idempotency and `outcome_unknown` rules of
[ble-link.md](ble-link.md) unchanged. The staging exemption is a device behaviour announced by the
tool's name and by `app.info`; an old phone treats a missing receipt as `outcome_unknown` and recovers
through §6, which is the same result.

## 6. Session rules

1. `app.begin` validates name, paths, sizes, extensions, totals against §2, that the sum of file
   sizes is ≤ `free_bytes`, and that no program is mid-install. A second `app.begin` carrying the
   same name and the same digest returns the existing session (resume); a different one while a
   session is open fails `busy`.
2. `app.put` writes `data` at `offset` of one declared file:
   - `offset` equals the file's next offset → append, return the new next offset;
   - `offset` is below it, the range `offset + length` lies entirely at or below it, and the bytes equal
     what is already staged → no change, return the same next offset (replay is safe);
   - `offset` is below it and the bytes differ or run past the staged end → `offset_mismatch`, nothing
     changes;
   - `offset` is above it → `offset_mismatch` with `next_offset`.
   A write whose `offset + length` exceeds the declared size fails `too_large` (checked first). The device keeps a running sha256 per file.
3. `app.commit` requires every file complete, every file hash equal to its declared hash, the manifest
   valid (§3) and `digest` equal to the recomputed one; otherwise nothing changes and the first bad
   path is reported. The swap is: rename any existing `/apps/<name>` to `/apps/.old_<name>`, rename the
   stage into `/apps/<name>`, remove the old copy. On boot the device finishes or rolls back an
   interrupted swap and deletes stages and `*.part` files. An app whose directory is incomplete is never
   listed or started.
4. A disconnect, an idle timeout or `app.abort` removes the stage. Installed apps are never altered by
   anything but a successful commit, `app.remove` or a later commit of the same name.
5. `app.run` and `app.remove` refuse an app that is mid-install; `app.run` stops a running app first.
   `app.commit` over a running app fails `running`; the host calls `app.stop` first.
6. An installed app carries the marker file `/apps/<name>/.devapp`, whose content is exactly the 64
   hex characters of its §4 digest (computed over the declared files, excluding the marker). It is
   written last into the stage, so the swap installs it atomically with the files. `app.info` reports
   the digest from it; a directory without a valid marker is a legacy app (listed if it has `main.py`,
   empty digest) and the runtime guard of §9 applies only to marked apps. Free-space accounting uses
   the device's block size, so `no_space` may refuse a bundle whose plain size sum would fit.

## 7. Host admission and the user's confirmation (phone)

- `app.begin`, `app.put`, `app.abort`, `app.commit`, `app.run`, `app.stop` and `app.remove` are
  **host-only**: an agent-origin `ble_link_call` of any of them is refused with `not_executed`
  (`host_only`) before the journal and the radio. `app.info` stays callable by an agent. Installs must
  never go through `ble_link_call`: its approval offers a standing grant that would cover every Link
  tool of every device.
- The Bot has four host tools (P26): `DeviceAppStage {files}` is read-only: it runs the static check of
  §9, computes the file hashes and the digest of §4, and returns them. `DeviceAppInstall {digest}`
  installs the staged bundle. `DeviceAppList {}` and `DeviceAppRemove {name}` (device-app-v1.5, below)
  read and remove what is installed. The device is resolved from the calling Bot's binding
  ([device-bot.md](device-bot.md)), never from a model-supplied id; a Bot without a binding does not see
  these tools, and a call from one is refused by the host.
- `DeviceAppInstall` raises one approval **on every call, including on a user's own turn**: a
  model-written program is not covered by "the user asked for an app". The card is once-only (no
  standing grant). Its visible text is the customer's (§12): the device's display name, the app
  title first, a one-line purpose, the permissions in plain words, a replace notice and one line
  with the file count and size; it shows no digest, path or Link device id. The approval is
  bound to the full digest (and to the device key and app name in the approval `resource`); the
  visible text never weakens that binding.
  The approval is obtained **before** any radio use and is spent by the install; it is never held
  across the transfer.
- A decline, an expired approval or any validation failure ends with nothing sent to the radio.
- **Authorization (device-app-v1.3).** The per-install approval above is the user's authorization of
  the eight `app.*` calls the install makes. The phone therefore does not require the Settings →
  Bluetooth devices grant for them: the Link entry waives the grant check for a **user-origin** call
  of exactly the eight device-app-v1 names (`app.info`, `app.begin`, `app.put`, `app.abort`,
  `app.commit`, `app.run`, `app.stop`, `app.remove`) and nothing is granted or remembered. Every other
  check (connected, advertised tool, busy, host-only) is unchanged; an agent-origin call keeps the
  Settings grant requirement and the host-only refusal; any other tool keeps its grant. The App's
  preflight no longer returns `device_not_authorized` (the code stays reserved, unused).
- The host then drives begin → put* → commit strictly serially (Link allows one call at a time) with a
  fresh journal key per call derived from the install id and call number, and after the install ends
  prunes that install's staging intents from the phone's Link journal (a staging call must not use
  the lifetime budget of 4096 intents). It never retries a durable call with a new key; an
  `outcome_unknown` commit is resolved with `app.info` (installed digest equal to the declared one,
  or not). An interrupted install leaves the old app intact (§6).
- After the install the host writes a durable `ui.system_event{event:"device.app.install"}` carrying
  the device key, the digest, the file list and the approval id as the author; it never records
  success it did not observe. `DeviceAppInstall` raises its own approval and so skips the generic
  ask-authorize; a durable (routine or task) principal gets a pending outcome and installs nothing
  until the user answers.
- **After the commit (device-app-v1.4).** The host calls `app.run` for the just-installed app on
  the same user-origin path and under the same waiver: the user approved this install, and the card
  says it runs on the device. A failed `app.run` is not an install failure; it is reported as
  installed-but-not-opened (§12) and nothing is rolled back.
- **Unknown commit outcome (device-app-v1.4).** When the commit reply is lost or the link drops after
  `app.commit` was sent, the phone reads `app.info` (after the link is back, a few attempts) and
  returns a definite verdict: the declared digest installed under the name → installed; the name
  absent or another digest → not installed, the old app unchanged. Only a device that cannot be read
  stays `outcome_unknown`, and then the customer is told to ask for the install again (same digest,
  so repeating is safe). The commit itself is still never sent twice.
- **Interrupted transfer (device-app-v1.4).** A call cut off before `app.commit` was sent
  (disconnect, device reboot or watchdog) gets one automatic retry, only after the link is connected
  again, with the same name and digest (so §6 rule 1 applies) and a new install id (new staging
  journal keys). A second interruption, or any other failure, is not retried. A call cut off while
  `app.commit` is in flight is never a transfer failure: it is an unknown outcome, settled as above.
- **List and remove (device-app-v1.5).** After an install the customer can neither see what is on the
  device nor stop or delete an app, and `app.stop` / `app.remove` have no other caller; the Bot gets two
  tools, visible under the same rule as `DeviceAppStage` / `DeviceAppInstall` (listed for all callers,
  hidden per caller unless bound, refused by the host when unbound):
  - `DeviceAppList {}` takes no argument. It is read-only and needs no approval: after the link checks
    of the install path (connected, tools advertised) it reads `app.info` once on the bound device and
    returns `{ok:true, count, apps:[{name,title,version?,running}], message, hint}`. `title` falls back
    to `name`; every string the device reported is sanitized and clipped (it is untrusted display
    text). `message` is the customer text (§12). A failure is `{ok:false, error:{code:"list_failed",
    reason}, message, ...}` with the sentence from §8.2.
  - `DeviceAppRemove {name}` stops the app when it is running and removes it. `name` must pass the §2
    app-name rule; anything else (a path, another case, an extra member such as a device) is refused
    `invalid_arguments` before any card or radio use. It raises one **once-only** approval **on every
    call, including on a user's own turn**, before any radio use: the card is the §12 removal card,
    bound to the device key and the app name in the approval `resource`, offered no standing grant,
    with the same 330 s card and the same 10 s local reminder as the install card. A decline, an expiry
    or a cancel deletes nothing and sends nothing to the radio.
  - After the approval the host reads `app.info` (the link checks first); an app that is not listed
    ends `not_found` with nothing removed. It calls `app.stop` only when **that** app is running (a
    failed stop ends `stop_failed` and `app.remove` is never sent), then `app.remove {name}` once, as
    the user origin under the v1.3 waiver (both names are among the eight). A remove call that was cut
    off or got no reply is never repeated: the host reads `app.info` again; the name absent means
    removed, present means `not_removed`, an unreadable device stays `outcome_unknown` (and the
    customer is told to ask again, which is safe because removing is idempotent for the customer).
    A device refusal keeps its §8 code in `error.reason`.
  - One operation per device: while an install or a removal holds the device (waiting for its
    approval or on the radio), another `DeviceAppRemove` or `DeviceAppInstall` and a `DeviceAppList`
    answer `busy`; a retry of the same removal is told the real state (same name awaiting approval, or
    being removed) and raises no second card.
  - Success is `{ok:true, removed:true, name, was_running, audit_recorded, message, hint}`; failure is
    `error.code` `remove_failed` (with `error.reason` the device or installer code), `outcome_unknown`,
    `busy`, `permission_denied` or `invalid_arguments`, plus `message` (§8.2 sentence, also the visible
    text), `hint` and a clipped `diagnostic`.
  - Audit: after an observed removal the host writes a durable
    `ui.system_event{event:"device.app.remove", device, name, title?, was_running, author}` through the
    same auditor as the install (`author` is the same approval author record; no digest, no files).
    A failed write is `audit_recorded:false`; success is never claimed beyond what was observed.
- The device Bot's authoring guide is host-authored and static (versioned in the App, injected into
  that Bot's persona); nothing the device reports is quoted into it.

## 8. Error codes

`bad_request`, `forbidden_path`, `too_large`, `no_space`, `busy`, `bad_session`, `offset_mismatch`,
`hash_mismatch`, `digest_mismatch`, `not_found`, `running`, `host_only` (phone-side), `declined`
(user or on-device). A device never invents another code for these meanings.

### 8.1 Customer wording (device-app-v1.4)

The customer never opens Settings, reads logs or sees codes. Result fields keep the stable
machine codes (`error.code`, `reason`); the visible text and `message` are one Chinese sentence from
the table below, and the Bot is told (authoring guide) to relay `message` in its own words without
codes, digests or tool names. Internal instructions to the model (for example that the install
record was not written) live in the `hint` field only, never in the visible text. A code that is not
in the table gets the generic sentence, never the code.

| Code | Sentence |
| --- | --- |
| `no_space` | 设备空间不够，请先删掉一个设备应用 |
| `busy`, `link_busy` | 设备正在传输另一个应用，稍后再试 |
| `device_not_connected` | 设备没连上，请靠近设备并确认蓝牙已开 |
| `device_info_failed` | 读不到设备的状态，请靠近设备并确认蓝牙已开 |
| `device_not_found` | 没找到这台设备，请到设备页面确认它还在列表里 |
| `device_tools_missing`, `device_protocol_mismatch` | 这台设备不支持安装应用，可能需要先升级设备 |
| `stop_failed` | 设备上的应用停不下来，请在设备上长按确定键退出后再试 |
| `running` | 设备上的应用还开着，没能替换。请在设备上长按确定键退出后再试 |
| `call_failed`, `transfer_interrupted`, `too_many_resumes`, `protocol`, `not_executed`, `bad_session`, `offset_mismatch` | 传输中断，设备上原来的应用没有改变。要重试吗？ |
| `hash_mismatch`, `digest_mismatch` | 内容和你确认的不一致，没有安装，设备上原来的应用没有改变。要重试吗？ |
| `commit_not_installed`, `not_installed` | 没有装上，设备上原来的应用没有改变。要重试吗？ |
| `outcome_unknown` | 没能确认设备上有没有装好；请靠近设备并确认蓝牙已开，然后让我再装一次，装不上也不会影响原来的应用 |
| `too_large`, `forbidden_path`, `invalid_bundle`, `bad_request`, `not_found`, `host_only`, `declined`, `cancelled`, `device_not_authorized` | one plain sentence each (`DeviceAppCustomerText.table`) |

A §9 static-check failure is only for the Bot to fix; its text is a plain reason with the line
(`检查没通过：用了 f-string（main.py 第 3 行），改好后再检查一次`), and `code`, `path`, `line` stay in the
fields.

### 8.2 Remove and list wording (device-app-v1.5)

`DeviceAppRemove` and `DeviceAppList` use their own sentences (never "安装"), keyed by the same machine
codes (`DeviceAppCustomerText.removeTable`, `listTable`). A code not in a table gets that tool's generic
sentence, never the code. `error.code` stays remove_failed or list_failed (§7) and the code is in
`error.reason`.

| Code | Sentence |
| --- | --- |
| `device_not_found` | 没找到这台设备，请到设备页面确认它还在列表里 |
| `device_not_connected` | 设备没连上，请靠近设备并确认蓝牙已开 |
| `device_tools_missing`, `device_protocol_mismatch` | 这台设备不支持设备应用，可能需要先升级设备 |
| `device_info_failed` | 读不到设备上的应用，请靠近设备并确认蓝牙已开 |
| `not_found` | 设备上找不到这个应用，可能已经删掉了 |
| `stop_failed`, `running` | 设备上的应用停不下来，请在设备上长按确定键退出后再试 |
| `busy`, `link_busy` | 设备正忙着处理另一个应用，稍后再试 |
| `bad_request` | 设备没能理解这次操作，请稍后再试一次 |
| `host_only`, `declined`, `cancelled`, `device_not_authorized` | one plain sentence each (`removeTable`) |
| `call_failed`, `not_executed`, `protocol`, `transfer_interrupted` | 没能删除，设备上的应用没有改变。要重试吗？ (list: 读不到设备上的应用，请靠近设备并确认蓝牙已开) |
| `not_removed` | 没有删掉，设备上的应用没有改变。要重试吗？ |
| `outcome_unknown` | 没能确认设备上有没有删掉。请靠近设备并确认蓝牙已开，然后让我再看一下；没删掉的话也不会有别的影响。 |

## 9. Static check (phone) and runtime guard (device)

The phone has no Python parser, so the check is on **tokens** (the Python 3 lexical grammar) and is
deliberately conservative: it can reject a harmless program, never the reverse of what is listed.
It does not prove the program is syntactically valid; the device's compile step reports that. The
device enforces the same lists at run time with a restricted `__import__` and builtins. Neither is a
security boundary against a hostile program; both exist so the user's confirmation concerns code that
cannot trivially reach the radio, the flash or other apps. A failed check yields the code, path and line of the first violation: `size` first (line 0), then
token-rule violations ordered by path, line and rule number, and `exit_path` (line 0) only when nothing
else failed. Codes: `size`, `lex`, `fstring`, `import`, `name`, `underscore`, `perm`, `except`, `exit_path`.

Strings and comments are ignored by every rule below except 1 and 2.

1. Size and text: the file is valid UTF-8, has no NUL, is within §2 and tokenizes without a lexical
   error (unterminated string, inconsistent indentation). The line of a lexical error at end of input
   (open bracket, unterminated triple quote, dangling backslash) is the line where the construct
   opened. The per-app total, the file count and the required `main.py` and `app.json` are checked by
   `DeviceAppStage` with code `size`, path `""` and line 0; the per-file vectors cover single files.
2. String prefixes: an `f`/`F` prefix (f-strings) is rejected.
3. Imports: `import a.b as c, d` and `from x import …` are checked on the module's first segment.
   Allowed: `time`, `math`, `random`, `json`, `gc`, `struct`, `array`, `micropython`, `lcd`, `keys`,
   `ui`, `kit` (the frozen style kit of the device firmware); `audio` and `mic`-functions as in rule 6; `battery` when `perms` lists it; and modules that
   are `.py` files of the same app. Relative imports and `import *` are rejected.
4. Names: any identifier token equal to `exec`, `eval`, `compile`, `execfile`, `open`, `__import__`,
   `getattr`, `setattr`, `delattr`, `globals`, `locals`, `vars`, `dir`, `breakpoint`, `input`,
   `__builtins__`, `machine`, `os`, `sys`, `socket`, `network`, `bluetooth`, `_thread`, `esp32`,
   `_passport`, `apprt`, `settings` is rejected wherever it occurs (variable, attribute or call).
5. Underscores: an identifier that starts and ends with `__` other than `__name__` and `__init__`, and any attribute
   (an identifier directly after `.`) that starts with `_`, is rejected.
6. Permissions: `audio` needs `perms` to contain `audio`; the identifiers `record_wav`, `readinto`,
   `mic_gain` additionally need `mic`; `battery` needs `battery`. A listed permission that no import
   uses is a warning only.
7. Exceptions: after `except`, a `:` directly, or a name `BaseException` or `KeyboardInterrupt` before
   the `:`, is rejected (it would swallow the user's stop).
8. Exit path: `main.py` or one of its sibling modules contains the tokens `keys` `.` `get` or
   `keys` `.` `pressed`.

## 10. Platform status and requirements on the device

| End | State |
| --- | --- |
| iOS host tools, approval, static check, journal prune | `target` |
| MicroPython device (`link_peripheral`, installer, runtime guard) | `target` |
| Android | `target`; blocked by GAP-20 |

A device that offers these tools must, while the installer is enabled: have no unauthenticated
remote code-execution, arbitrary-file-write or key-injection interface (the admin HTTP API off, or
token-protected without `exec`, file write and key injection); bond with the phone only inside a
pairing window the user opens on the device, with LE Secure Connections, and reject writes on an
unencrypted link; keep the stop gesture independent of the installed program; and finish or roll back
an interrupted install at boot.

## 11. Fixtures and checkers

| File | Purpose |
| --- | --- |
| [schema/device-app-vector.schema.json](schema/device-app-vector.schema.json) | closed shape of one vector |
| [golden/device-app.jsonl](golden/device-app.jsonl) | name, path, manifest, digest, static check and `app.put` vectors, valid and invalid |
| [spec/v1/tools/test_device_app_golden.py](../../v1/tools/test_device_app_golden.py) | pins the file hash, validates the schema, replays every vector through a reference oracle |

The oracle is a spec checker, not runtime conformance. The phone's validator and the device's guard
must each run the same file through their real functions.

## 12. Customer-visible text (device-app-v1.4)

- **Approval card.** Title `在「<设备显示名>」上安装「<应用名>」？` (the device's display name from the
  phone's own device list; `你的设备` when unknown). Body, first line `应用：<应用名>`; then
  `Bot 写了一个小程序，装好后在设备上运行；会用到：<权限>。装之前请确认。` (permissions `audio`→喇叭,
  `mic`→麦克风, `battery`→电量; none: `不需要用到设备的喇叭、麦克风等`); then, when the phone knows an
  app of that name is on the device, `会替换已有的「<名>」并先停止它`; then `共 N 个文件，X KB`. The
  replace notice is read from phone-side state only (the approval precedes any radio use, §7).
- **Success.** `已装好「<应用名>」并已在设备上打开。长按确定键退出。` (holding OK 0.7 s sends `back`;
  the device force-stops the app at 3 s). If `app.run` failed: `已装好，但没能自动打开，请在设备上选「<应用名>」打开。`
- **Result fields.** Success adds `opened` (boolean), `message`, `hint` (and `run_reason` when `app.run`
  failed); a failure carries `error.code` (unchanged: `install_failed`, `outcome_unknown`, `busy`,
  `digest_mismatch`, `permission_denied`, …), `error.reason` (the device or installer code), `message`
  (the §8.1 sentence), `hint` and a clipped `diagnostic` for the model.
- **Removal card (device-app-v1.5).** Title `要从「<设备显示名>」上删除「<应用名>」吗？` (`你的设备` when the
  name is unknown; `<应用名>` is the title the phone last saw for that app, else the app name); body, first
  line `应用：<应用名>` (the approval notification reads it), second line
  `删除后不能恢复，需要的话让我重新做一个。`. No digest, name code, path or Link device id is shown; the
  device key and the app name are in the approval `resource`. The local reminder after 10 s says
  `「<应用名>」在等你点「允许」，才会从设备上删除`.
- **List and remove text.** List: `设备上现在有 N 个设备应用：` and one line `「<标题>」` per app, with
  `（正在运行）` appended to a running one; none: `设备上现在没有设备应用。`. Remove success:
  `已从设备上删除「<应用名>」。` or, when the app was open, `已把「<应用名>」停掉并从设备上删除。`.
- **Authoring guide (v3, was v2).** The guide gains a section telling the Bot it can list and remove (names
  come from the list, the confirmation card appears, only `ok` means done). Before `DeviceAppStage` the Bot says that a confirmation card will appear
  and to tap 允许 within 2 minutes; after the install it says the app is open and how to quit; it
  never says digest, error code or tool name to the customer.
