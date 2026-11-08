# Android host for the native Android ADB tools

## 0. Summary

```yaml
change: PC-20261108-android-adb-host
contracts: [P05, P08, P09, P12, P16, P18]
status: implemented
breaking: false
base: 0e9ad261
contract_revision: spec/v1/native-mcp.md@PC-20261105-native-ssh-adb (unchanged wire contract)
```

## 1. Identification and roles

- Trigger → current → expected: PC-20261105-native-ssh-adb added `/mcp/native` with 26
  `android_*` tools, the ADB RSA identity, receipts and the Android ADB settings page on
  iOS only; the Android app had none of it (module map `PhoneDSHADB: absent`, page contract
  `match: missing`). Expected: the Android host serves the same tools with the same
  contract, or the missing parts are recorded with evidence.
- Coordinator / contract owner / implementer / reviewer: one agent in worktree
  `ws/android-adb`; the wire contract is **not** changed. This record only adds the second
  implementation, its status line in `native-mcp.md`, the regenerated page binding and the
  module-map row, plus one contract change request (§6) that is not acted on here.
- Owning contracts: P05 `spec/v1/native-mcp.md` + `spec/v1/golden/native-mcp/*.json`;
  P09 `spec/ui/v1/pages/android-adb-settings.json`; P16 the existing `PDSH_PHONE_MCP_URL` /
  `PDSH_PHONE_MCP_TOKEN` Worker variables (`plugins/profile/phone.worker.cordis.patch.yml`);
  P18 the persisted target (`phone-dsh.android-adb.configuration.v1`) and receipts;
  P08/P12 `spec/platform/android-module-map.json`.
- Producers / consumers: Kotlin `:net` server and loopback route (new end), `:engine` Worker
  env, `:app` composition root and `:lib` page; the shared Worker bundle is unchanged and
  already consumes the two env variables; the Android device over ADB.

## 2. Contract delta

| Area | Before → after |
| --- | --- |
| P05 native MCP | iOS only → iOS and Android. Same methods, tool names/order/descriptions/schemas, argument validation, Android shell commands, result text, `isError` rules, idempotency/receipt semantics, serialization, cancellation, 16 KiB request bound, `serverInfo` `phone-dsh-android 1.0.0` and `instructions`. Android mounts exactly `/mcp/native` behind the existing token gate; `tools/call` answers 503 `unavailable` while D14 admission is closed; origin stop cancels and settles pending work (bounded 5 s). |
| P16 Worker env | Android sets `PDSH_PHONE_MCP_URL=<origin>/mcp/native` and `PDSH_PHONE_MCP_TOKEN=<per-start token>` when the server is mounted (engine-owned, wins over host values), as iOS does. No new variable. |
| P18 persistence | Android stores the iOS JSON shape under the iOS key in app-private SharedPreferences (`commit()`); RSA PKCS#8 in `AndroidSecureStore` (`phone-dsh.android-adb.rsa.v1`, Keystore AES-GCM, no-backup dir; Unreadable fails closed); receipts `noBackupFilesDir/android-adb-receipts/<sha256(key)>.json` (`{"fingerprint":base64,"result"?}`, temp + fsync + atomic rename). Android-local; never read by another platform. |
| P09 UI | `AndroidADBSettingsPage` + settings row `Android ADB` (destination `ANDROID_ADB`, route `PdshRoute.AndroidAdb`). Copy says 这台手机 instead of iPhone and states that Worker `adb push/pull` is unavailable. |
| P08/P12 module map | `PhoneDSHADB: absent` → `com.phonedsh.adb` in `:net`, `mapped`. No JNI/FFI/ABI change. |
| P01 / P03 / P17 | none — Android does **not** advertise `accelerator:adb`; no exec argv, frame or HELLO change. |

Self-check: no second envelope, no new field, error code, env variable or dependency. The
fingerprint is SHA-256 of sorted-key JSON of `{name, arguments, host, port}`; it is
host-local (receipts never cross platforms), so it need not be byte-equal to Swift's.

## 3. Compatibility and release

| Producer → consumer | Compatibility |
| --- | --- |
| old Android app → Worker | No env variables, `mcp-phone` stays disabled (`disabled: !process.env.PDSH_PHONE_MCP_URL`), as before. |
| new Android app → Worker | The shared Worker mounts `mcp__phone__android_*` exactly as on iOS. |
| new → new device | ADB is the device's protocol (shell_v2, AUTH RSA); TLS pairing ports are refused as on iOS. |
| persisted data / rollback | New keys and files only. Rollback leaves an unused preference, a SecureStore entry and receipt files; no WAL/journal migration. |

## 4. Ownership and evidence

- Paths: `android/net/src/main/kotlin/com/phonedsh/adb/**`,
  `android/net/src/main/kotlin/com/phonedsh/loopback/{NativeMcp,LoopbackService,LoopbackServer}.kt`,
  `android/engine/.../{WebViewEngine,DemoEngineFactory,WorkerEnvironment}.kt`,
  `android/app/.../{AndroidAdbHost,HostShell,ProbeEngineViewModel}.kt`,
  `android/lib/.../{AndroidADBSettingsPage,SettingsPage,UiPageTags}.kt`, `ui/nav/*`.
- Shared vectors through the real Kotlin server: `tap.json` (also over real HTTP through the
  loopback gate), `connect.json`, `package-management.json` (`AdbMcpGoldenTest`,
  `LoopbackNativeMcpTest`). `file-transfer.json` and `ble-devices.json` are classified as
  not served on Android; the test fails if a new vector is not classified.
- Results: see the PR / commit handoff block. No device, emulator or real adbd was used.
- Not verified: a real Android target (auth prompt, `screencap`, `pm install` stdin), the
  Keystore path on hardware, the Worker's `mcp-phone` client against the Android origin in a
  WebView, renderer/engine restart with an in-flight call.

## 5. Revision history

| Revision | Owner | Reason | Notified ends |
| --- | --- | --- | --- |
| PC-20261108-android-adb-host | android-adb implementer | Add the Android end of the frozen P05 contract; record §6. | Android host; iOS host (no change) |

## 6. CONTRACT CHANGE REQUEST (open, not implemented)

```
CONTRACT CHANGE REQUEST
Contract: P05 @ spec/v1/native-mcp.md (PC-20261105-native-ssh-adb)   Clause: native-mcp.md §"Worker ADB file transfer bridge"; ADBTools.swift descriptors; ADBMCPServer.swift `instructions`
Problem: The tool descriptions and the `initialize.instructions` text are one shared
  contract but are written for the iPhone host: "directly from iPhone", "this iPhone
  debugging key", "iPhone workspace APK", and "For file transfers use the Worker bash
  commands adb push/pull ... /dsh/transfers/NAME streams up to 1 GiB on iPhone disk".
  On Android the Worker registers `adb` only when HELLO advertises `accelerator:adb`
  (plugins/shell-ext/src/commands.ts:261-262), which the Android host does not
  (no exec-bridge `adb` accelerator, no native transfer store). A model following the
  instructions on Android gets `adb: command not found`. Android serves the text verbatim
  because AGENTS.md §3.3 forbids a platform-only branch.
Proposal: Make the text host-neutral ("this phone") and state the transfer bridge
  conditionally ("when the Worker has the `adb` command"), or let the host compose the
  transfer sentence from its advertised accelerators under an explicit clause. Either way
  freeze it in native-mcp.md with a vector for `initialize` and `tools/list`.
Affects: iOS ADBMCPServer/ADBTools (text), Android AdbMcpServer/AdbTools (text), Worker none.
```

Implementing the Android `accelerator:adb` (exec-bridge argv `adb --pdsh-v1 push|pull|stat`,
SCP NDJSON records, `/dsh/transfers` native store, 1 GiB / 3600 s streaming) is a separate
P01/P03/P17 change and is not part of this record.
