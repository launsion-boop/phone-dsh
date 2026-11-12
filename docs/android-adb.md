# Android ADB control from iPhone

Phone DSH can connect directly to a configured Android TCP/IP ADB endpoint on
the LAN. The iPhone app implements the ADB protocol with Network.framework;
there is no desktop ADB server in the control path and no executable in the
Worker. The `PhoneDSHADB` SwiftPM product owns the transport, RSA identity,
command harness, settings and MCP tool endpoint.

## Connect

The probe app starts new sessions in `danger-full-access` mode (approval never).
Existing sessions retain their selected permission mode; it can be changed in
the session permissions menu. This does not grant Android root or bypass its
debugging authorization.

1. Put both devices on the same reachable Wi-Fi network. Enable Android
   developer options and USB debugging.
2. Enable **TCP/IP ADB** on Android. If the device has no network-ADB switch,
   connect it to a computer once and run `adb tcpip 5555`. After this setup,
   the iPhone connects directly; the computer is not a relay. Android may
   require this setup again after reboot.
3. Tell the iPhone agent to connect to the Android host and port; it calls
   `android_connect` to enable control, persist the target and check connectivity.
   Alternatively, open iPhone **Settings → Android ADB**, enable control, enter the Android
   IP/hostname and TCP/IP ADB port (usually `5555`), then save.
4. Tap **Test connection**, unlock Android and accept the iPhone's debugging
   key. A successful check returns the model, Android version and screen size.
5. Ask the agent, for example: “检查 Android 连接，截图，然后打开系统设置。”

This implementation supports the classic RSA-authenticated TCP/IP transport
and requires `shell_v2` (Android 7+). **The six-digit pairing-code/TLS transport
in Android 11+ Wireless debugging is not implemented.** Its pairing/connect
ports are not interchangeable with the TCP/IP port. See Google's
[ADB connection instructions](https://developer.android.com/tools/adb).

## Discovery

Typing the TV's address is optional. In iPhone **Settings → Android ADB**, a
scan of the current Wi-Fi network lists plausible TVs and connects to one with no
input. A scan is one explicit, bounded foreground pass, with no persistent
listener and no background polling; on iOS it merges three sources:

| Source | Contribution |
| --- | --- |
| Bonjour catalog | `_androidtvremote2._tcp`, `_googlecast._tcp`, `_airplay._tcp` and `_roku-rcp._tcp` advertisements, resolved within the same pass |
| Unicast port probes | TCP 5555, 6095, 6091, 8009, 7000, 6466, 6467 and 8060, at most 64 concurrent, 400 ms per connection |
| Remembered devices | TVs connected before, from the local device list, offered even when this pass observes nothing |

**Platform difference (this version).** The Bonjour catalog and the remembered
device list above are **iOS-only**. The Android host runs the same bounded port
scan but has no DNS-SD catalog and keeps no remembered list or last endpoint; it
still saves the one manual target through the existing ADB settings. A TV that
only advertises Bonjour is therefore not listed on Android, and an Android scan
starts from port evidence only.

On iOS, probes cover every up, non-loopback IPv4 subnet reported by `getifaddrs`;
on Android, only the current Wi-Fi network's `wlan*` interface, with the socket
bound to that network. Both exclude the network and broadcast addresses and cap
the pass at 4096 hosts. A pass stops at 8
seconds and returns partial results. Ranking favors hosts that answer on 5555,
then remembered TVs, then hosts with only Xiaomi (6095/6091), TV-shaped Bonjour
or media-port evidence; a generic Bonjour advertisement alone never proposes a
host. Every candidate is listed as `host:5555`, because 5555 is the endpoint ADB
dials, even when the evidence came from another service on that host. A scan adds
no MCP tool: the agent path stays `android_connect`, and manual host/port entry
keeps working.

**What a scan cannot do.** SSDP/UPnP/DLNA multicast discovery is **not
supported**: the app has no `com.apple.developer.networking.multicast`
entitlement, so it cannot join the SSDP group (UDP 1900). Bonjour browsing uses
the system DNS-SD resolver and needs no such entitlement; SSDP has no equivalent
here. A TV that only advertises DLNA is therefore not discoverable; enter its
address by hand. A host app must declare all four service types in
`NSBonjourServices`; an undeclared type yields no Bonjour hits. Android 11+
Wireless debugging is still unsupported: the six-digit pairing code and the TLS
transport are not browsed or dialed, so the TV must expose the classic
RSA-authenticated TCP/IP port (run `adb tcpip 5555` from a computer where the
device has no network-ADB switch). A port hit is **candidate evidence, not device
identity**: an open 8009, 7000, 6466, 6467 or 8060 says a TV-shaped service
exists on that host, not that ADB is enabled, and an open 5555 does not prove the
host is the TV the user meant. Model, serial and Android version are known only
after authorization.

**Connecting.** Selecting a candidate starts the same authorization as a manual
endpoint:

1. The connector dials `host:5555`. If this iPhone's key is not trusted yet, the
   TV shows its debugging authorization prompt; accept it with the TV remote.
2. While the TV reports the connection as unauthorized, a 4 s probe is retried
   after a 2 s gap for up to 90 seconds, and the attempt reports the elapsed
   wait. A host that never answers, a busy engine or a protocol violation ends
   it immediately; once the AUTH exchange has started, a closed or timed-out
   read is treated as the authorization wait.
3. After authorization, serial, model, Android release, screen resolution and the
   wlan0 MAC are read in one shell round trip. The endpoint is recorded as the
   last successful target and the TV joins the device list. A field the TV does
   not report, such as a restricted `wm size`, is left empty instead of failing
   the connection.
4. If 90 seconds pass without authorization, the attempt fails with guidance:
   allow this iPhone's debugging key on the TV under **Settings → Developer
   options**, check that USB debugging is still enabled, and when no prompt
   appears, revoke USB debugging authorizations so the TV asks again, then retry.

**Remembered devices (iOS).** The last **8** TVs are remembered, newest first,
keyed by ADB serial rather than address. Each record holds model, host, port,
wlan0 MAC and last-seen time; the endpoint of the most recent successful
connection is stored separately, so the last address is available without a new
scan. Records are keyed by serial, so a later connection to the same TV updates
that record in place instead of adding a second entry. Discovery itself buckets
candidates by address: a DHCP move is **not** followed from the old record alone,
because the TV must first answer at its new address (a scan hit) before the
record is updated. Forgetting a TV also clears the saved endpoint when it points
at that TV, so a remembered endpoint never points at a forgotten device. The list
and the endpoint are local to the app; they are not uploaded or shared with the
Worker. Android has neither list nor endpoint in this version.

## Tools

The existing official DSH MCP client mounts the native endpoint under `phone`:

| Tool name suffix (`mcp__phone__…`) | Behavior |
| --- | --- |
| `android_connect` | Enable control, save host/port and check connection without visiting Settings |
| `android_status` | Model, OS release and display size |
| `android_screenshot` | PNG image content, preserving binary bytes |
| `android_tap` | Tap screenshot pixel coordinates |
| `android_swipe` | Swipe or long press; duration 1–10000 ms |
| `android_input_text` | Printable ASCII into the focused field |
| `android_key` | Home, Back, Enter, app switch, volume and numeric keys |
| `android_launch_app` | Launch an installed package |
| `android_ui_dump` | Accessible UI hierarchy and bounds |
| `android_shell` | Shell command as Android's ADB shell user, up to 120 s |
| `android_list_packages` | Installed packages, APK paths and installer; filter by name, system/third-party, enabled state and user |
| `android_package_info` | APK/split paths, versions, permissions and package metadata |
| `android_install_apk` | Install one APK from the iPhone workspace or an existing Android path |
| `android_uninstall_app` | Uninstall by package ID for a user; optional keep-data |
| `android_force_stop` | Stop an app without uninstalling it |
| `android_clear_app_data` | Delete the selected app's user data/cache, including login state |
| `android_set_app_enabled` | Enable or disable an app for a user |
| `android_install_existing_app` | Restore an on-device package for a user |
| `android_app_permission` | Grant/revoke a declared runtime permission |
| `android_list_users` | Users/profiles and foreground user |
| `android_open_uri` | Open a web URL or deep link with an Android VIEW intent |
| `android_logcat` | Bounded recent logs, buffer and priority filters |
| `android_device_info` | Model, OS/API, display, battery and storage |
| `android_list_apk_files` | Find APK installer files in an Android directory |
| `android_delete_apk_file` | Delete one APK installer in shared storage or `/data/local/tmp` |
| `android_command_help` | Read the actual device's help for package, activity, input, settings, files, logs or services |

Screenshot coordinates are **pixels**, not normalized coordinates. The active
model must declare image-input support for the official MCP client to project
images into its context; `android_ui_dump` also works with text-only models.
Protected Android screens can refuse capture or produce black images.
Unicode text injection needs a compatible Android IME; unsupported text is
rejected explicitly rather than silently dropped. No helper APK is installed.

## Applications and APK files

“有哪些 APK” can mean installed applications or downloaded installer files.
Use `android_list_packages` for the former and `android_list_apk_files` for the
latter. Uninstalling takes a **package ID**, not a filename. Deleting a downloaded
APK does not uninstall its app. Package tools default to the current foreground
Android user; pass `userId` for a particular profile. Removing a system app for
one user does not delete the APK in the read-only system image.

For example, model tool arguments (with the usual `mcp__phone__` name prefix):

```json
{"name":"android_list_packages","arguments":{"kind":"third_party"}}
{"name":"android_package_info","arguments":{"packageName":"com.example.app"}}
{"name":"android_install_apk","arguments":{"source":"device","apkPath":"/data/local/tmp/example.apk"}}
{"name":"android_uninstall_app","arguments":{"packageName":"com.example.app","keepData":false}}
```

To install an APK from the iPhone, import/download it into the DSH workspace,
compute `sha256sum /dsh/workspace/downloads/example.apk` using the Worker shell,
then call `android_install_apk` with `source: "workspace"`, that absolute
`apkPath`, and the 64-character digest in `sha256`. The native host reads only
its configured materialized workspace, rejects symlinks and checks the digest
before opening ADB. A missing/mismatching copy means the file changed or is not
yet synchronized: verify the workspace and digest, then issue a new call. No
Android command is sent on a local validation failure.

The APK is copied into a bounded native buffer and sent through shell_v2 stdin
to `pm install -S <size> -`; no desktop binary, base64 tool payload or Android
temporary installer is required. Maximum file size is 128 MiB, timeout 120 s.
Slow transfers may hit that deadline. The package manager checks the APK's
manifest, signature and compatibility; a ZIP header alone does not make it a
valid installable APK. Install/uninstall/clear succeed only with exit code zero
and an explicit `Success` response. Failures such as signature mismatch, version
downgrade, insufficient space or device policy are returned to the model.

This tool installs **one APK**. AAB, XAPK, APKS and split-APK sets are unsupported.
`replaceExisting` defaults to true (`-r`); false requests `-R`, which requires
device support. `allowTest` (`-t`) and `grantPermissions` (`-g`) default to false.
Android/OEM versions may reject particular flags; consult the device's help.

## More Android commands

`android_command_help` reads help from the connected device; `android_shell`
accepts the remote shell command **without** the desktop `adb shell` prefix.
Examples for capabilities beyond the structured tools:

| Purpose | Remote shell command |
| --- | --- |
| Inspect running activities | `dumpsys activity activities` |
| Inspect an app's memory | `dumpsys meminfo com.example.app` |
| Inspect permissions | `pm list permissions -g -d` |
| Discover supported device features | `pm list features` |
| Read system settings | `settings list system` |
| Read a global setting | `settings get global airplane_mode_on` |
| Inspect network addresses/routes | `ip addr; ip route` |
| Inspect available service commands | `cmd -l; dumpsys -l` |
| Inspect processes | `ps -A` |
| Inspect files/storage | `ls -la /sdcard/Download; df -h` |

ADB shell permissions still apply: private app directories, signature
permissions and privileged operations may require device-side support/root.
For file transfers, run these in the **Worker bash tool**, not `android_shell`:

```sh
adb push /dsh/workspace/example.bin /sdcard/Download/example.bin
adb pull /sdcard/Download/example.bin /dsh/workspace/example-copy.bin
# Large files (up to 1 GiB), stored on iPhone disk:
adb pull /sdcard/Download/large.apk
adb push /dsh/transfers/large.apk /sdcard/Download/copy.apk
```

These commands use the saved Android endpoint and iPhone native shell_v2 binary
transport, without a desktop ADB server. Uploads read the acknowledged workspace
at the exec bridge revision. Downloads emit bounded transfer records and are
written by the Worker VFS through its normal WAL, never directly to its derived
materialized tree. An incomplete download preserves an existing destination;
uploads stage a temporary sibling then rename after a complete byte count check.
Each transfer supports one regular file (including empty/binary files). The
native `/dsh/transfers/NAME` store streams files directly to iPhone disk up to
**1 GiB (1,073,741,824 bytes)** with bounded memory and a one-hour deadline.
`adb pull REMOTE` defaults to this store. It maps to `Documents/adb-transfers`,
available in the iOS Files app via this app's file sharing. Files there remain
available as push sources but are outside the Worker's in-memory VFS. Use an
explicit `/dsh/workspace/NAME` destination for small files the model must read;
that route retains the device Worker single-file budget (at most 128 MiB) and
120-second deadline. The Worker bash tool's own timeout must also allow the
transfer to finish. Keep the iPhone app foregrounded for long transfers. The probe app configures
its independent Worker shell backstop to one hour; caller bash timeouts and
cancellation still apply. For large transfers request `timeoutMs=3600000`.
After an interrupted tool wait, query `adb stat /dsh/transfers/NAME` before
starting another download. It returns `running`, or `saved` with the actual byte
count after atomic commit, without contacting Android. A saved file can also be
queried after an app restart. Compare the saved size to the Android source size;
absence of a tool success message alone does not establish transfer failure.
Concurrent native transfers to the same local path are rejected. Directory recursion, preservation
flags, ADB sync service and six-digit/TLS pairing are not implemented. Remote
paths must be absolute file paths; pull may target an existing local directory.
The Android ADB shell user's filesystem permissions apply. Failed/interrupted
uploads can leave a remote temporary file or have an uncertain rename outcome;
inspect before retrying. `adb pair`, forwarding and reboot protocol services are
not supported.

Command references: [Android's ADB/pm/am documentation](https://developer.android.com/tools/adb),
[AOSP package manager command implementation/help](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android14-release/services/core/java/com/android/server/pm/PackageManagerShellCommand.java),
[AOSP shell_v2 framing](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/android14-release/shell_protocol.h).

## Integration and execution

```swift
import PhoneDSHADB

configuration.nativeMCP = ADBMCPServer.shared
try await ADBMCPServer.shared.setWorkspaceDirectory(materializedWorkspaceURL)
```

The host publishes `/mcp/native` on its existing loopback origin and derives
`PDSH_PHONE_MCP_URL` and `PDSH_PHONE_MCP_TOKEN` from the bound listener. The
Worker fetch bridge preserves the bearer and journal idempotency header on
that exact same-origin path. The DSH `mcp-phone` profile row registers the
tools, with a 130-second tool timeout. Rebuild the Worker image after changing
the profile or fetch bridge; an old image does not contain this routing fix.

The Android endpoint is persisted in native settings. `android_connect` accepts
a host and optional port (default 5555), enables control and saves the validated
target before checking it. Other tools use the saved endpoint. A failed check
keeps the target so authorization can be accepted and status checked again. The
2048-bit RSA private key stays in a device-only Keychain entry. Disabling
control takes effect on subsequent calls without restarting the engine.
One operation runs at a time; a concurrent call reports busy. Cancellation,
timeouts and host shutdown close the current ADB socket. Closing a socket
does not undo an input event or guarantee termination of a detached Android
process, so interrupted actions have an explicitly unknown outcome.

Journaled requests carry `X-PDSH-Idempotency-Key`. Before dispatch, the native
server writes a synchronized intent in Application Support under
`phone-dsh/android-adb-receipts`. Completed results are replayed; an unresolved
intent refuses to execute again after an app crash. Result bodies above
16 KiB (including screenshots) remain in the bounded in-memory cache, while
their persistent receipts retain a diagnostic instead of large media. Receipt
metadata is not automatically expired. A server instance admits at most 4096
distinct journaled calls; restarting clears the memory cache, not the durable
receipts. These receipts protect against process restart, not power-loss
transactions with Android. Unkeyed callers cannot be deduplicated.

## Verification

```sh
swift test --filter PhoneDSHADBTests
(cd plugins && node --test tests/llm-install.test.ts)
bash scripts/ci/smoke.sh
```

Tests cover ADB framing/checksums, RSA signatures and Android public-key encoding,
authorization fallback, binary shell output, real TCP timeout/cancellation,
MCP registration through the official DSH client, authenticated loopback access,
input validation, PNG content, serialization and restart deduplication. Package
tests cover command vectors, workspace confinement/digests, byte-exact APK stdin,
upload backpressure/early exit, and package-manager failure acknowledgements. The
macOS smoke asserts all 26 tools appear in the real WKWebView Worker.
These use simulated Android responses. Physical iPhone → Android operation
and the Android authorization dialog still require device acceptance testing.

Protocol references: [AOSP ADB protocol](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/android14-release/protocol.txt),
[AOSP public-key format](https://android.googlesource.com/platform/system/core/+/refs/heads/main/libcrypto_utils/android_pubkey.cpp),
[MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports).
