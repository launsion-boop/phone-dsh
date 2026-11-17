<!-- SPDX-License-Identifier: MIT -->
# Device app install v1 (`device-app-v1`)

Status: `target`. Nothing here is implemented on any end; no real-device run exists. The reference
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
- The Bot has two host tools (P26): `DeviceAppStage {files}` is read-only: it runs the static check of
  §9, computes the file hashes and the digest of §4, and returns them. `DeviceAppInstall {digest}`
  installs the staged bundle. The device is resolved from the calling Bot's binding
  ([device-bot.md](device-bot.md)), never from a model-supplied id; a Bot without a binding does not see
  these tools.
- `DeviceAppInstall` raises one approval **on every call, including on a user's own turn**: a
  model-written program is not covered by "the user asked for an app". The card is once-only (no
  standing grant) and shows the device, the app name and title, the file list with sizes, the
  permissions and the first 8 hex characters of the digest; the approval is bound to the full digest.
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
- The device Bot's authoring guide is host-authored and static (versioned in the App, injected into
  that Bot's persona); nothing the device reports is quoted into it.

## 8. Error codes

`bad_request`, `forbidden_path`, `too_large`, `no_space`, `busy`, `bad_session`, `offset_mismatch`,
`hash_mismatch`, `digest_mismatch`, `not_found`, `running`, `host_only` (phone-side), `declined`
(user or on-device). A device never invents another code for these meanings.

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
