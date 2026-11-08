# Native SSH/SCP and Android ADB tools

## 0. Summary

```yaml
change: PC-20261105-native-ssh-adb
contracts: [P01, P03, P05, P09, P12, P13, P16, P17, P18, P20]
status: implemented
breaking: false
base: 07585efb
contract_revision: 7eff4567
```

## 1. Identification and roles

- Trigger → current → expected: the iOS host had no native SSH/SCP connection or direct LAN ADB tools; add saved SSH/SCP accelerators, native Android MCP tools, and ADB file transfers over the existing exec bridge without changing channel frame envelopes.
- Coordinator, contract owner, implementer, reviewer/integrator: Codex coordinator; contract and implementation integrated in this branch.
- Owning contracts: P01 `spec/v1/channel.md`; P03 `spec/v1/exec.md`; P05 `spec/v1/native-mcp.md`; P13 shell capability source contract; P16 existing Worker environment contract; P17 `plugins/exec-bridge/src/client.ts` plus the accelerator clauses in `spec/v1/exec.md`; P18 persisted settings in `Sources/PhoneDSHSSH` and `Sources/PhoneDSHADB`.
- Affected producers/consumers: iOS PhoneDSH host and its loopback server; TypeScript Worker channel, shell extension, MCP installer and subprocess layer; the Android device over ADB; saved settings and receipt stores on disk. Rust/Kotlin channel codecs are unchanged and continue to ignore unadvertised accelerator names.

## 2. Contract delta

| Area | Before → after / clause |
| --- | --- |
| P01 capabilities | Host HELLO may advertise optional `accelerator:ssh`, `accelerator:scp`, and `accelerator:adb`; no new frame, field, or encoding. See `spec/v1/channel.md` and `spec/v1/exec.md`. |
| P03 exec behavior | SSH/SCP and ADB use existing journaled EXEC requests and terminal events. Remote SSH/SCP writes are intentional remote effects; local materialized mounts remain read-only. ADB file transfer has bounded sizes/deadlines and atomic destination commit rules in `native-mcp.md` and `docs/android-adb.md`. |
| P05 native MCP | Add authenticated same-origin `/mcp/native` for JSON-RPC MCP; tool calls honor admission/cancellation and use a durable receipt store. No second listener or altered `/mcp` proxy semantics. |
| P13 capability surface | Worker shell capability contract exposes SSH/SCP/ADB names through the existing host capability list; tool argument schemas and existing `phone` namespace are unchanged. |
| P16 environment | iOS launch sets the existing `PDSH_SHELL_TIMEOUT_MS` backstop to 3,600,000 ms for native 1 GiB transfers; caller deadlines and cancellation remain authoritative. No sandbox mode is forced. |
| P17 exec bridge | Reuse the existing `argv` and SCP NDJSON records; ADB workspace transfer remains VFS/WAL committed by Worker, while the separate native transfer path streams bounded data and does not materialize into workspace. No new envelope or version field. |
| P18 persistence | Save SSH connection profiles/host-key pins and ADB target/transfer receipts using their existing versioned or fixed-key stores. Side-effect receipts prevent blind replay; they are not an atomic transaction with a remote server/device. |
| P09 UI | Add settings rows and connection/configuration forms for SSH and ADB; UI state shape outside these feature pages is unchanged. |
| P12 | `none` — Swift package target/dependency wiring only; no FFI/JNI/native ABI changed. |
| P20 | `none` — Loopback route wiring changed, while Worker image packaging, manifest, and asset bytes are unchanged. |

Self-check: no second wire envelope, frame type, error namespace, or version negotiation was added. Existing exec and MCP identifiers retain their meaning. New accelerators are optional; an older host does not advertise them, and the worker follows its existing unsupported/local-fallback behavior.

## 3. Compatibility and release

| Producer → consumer | Compatibility |
| --- | --- |
| old → new | Old workers do not request the new accelerator names and continue using existing capabilities. Existing HTTP MCP clients continue through `/mcp`. Existing settings remain readable. |
| new → old | An old host omits the new HELLO capabilities, so the new Worker cannot dispatch these commands as host accelerators. The native app endpoint is only configured when the new host supplies it. Older app versions ignore new settings/receipt keys; downgrading loses access to the new features but does not rewrite old keys. |
| new → new | New host and Worker use existing EXEC framing plus the `/mcp/native` contract; file bounds, deadlines, receipt identity, and cancellation are enforced as specified. |
| persisted old data → new / rollback | SSH/ADB stores are additive and independently keyed. No old WAL, journal, or workspace manifest is migrated. Rollback can leave unused new settings and receipts; old code does not interpret them. |

- Version decision: no channel or exec-bridge major bump; optional capability negotiation gates the accelerator calls. `/mcp/native` is an additive endpoint on the authenticated origin.
- Artifact ordering: ship the app/native host and Worker image that both understand these tools together. Rollback to an old Worker/app disables the new capabilities; outstanding remote side effects must be reconciled via their receipts/status rather than blindly retried.
- `target`/`draft` clauses: P17 still has GAP-06 (no standalone `spec/exec-bridge-v1`); this change records only the present bridge shapes and does not close that gap.

## 4. Ownership and evidence

- Implementer paths: iOS SSH/ADB modules and probe UI; Loopback native MCP route; Worker channel/shell/MCP/subprocess integration; protocol docs, goldens, and registry.
- Shared fixtures: `spec/v1/golden/frames/exec-req-2.json`, `exec-req-3.json`; `spec/v1/golden/native-mcp/*.json`; Swift SSH/ADB tests and Worker SSH/SCP/ADB tests.
- Runtime evidence: `NOT_RUN` in this integration pass. No Swift, Worker, simulator, device, or end-to-end tests were run.
- Contract/spec checker: `NOT_RUN` in this integration pass.
- Not verified: iPhone build/device connectivity, Android device ADB behavior, 1 GiB transfer on hardware, cancellation/reconnect on a live device, old/new binary interoperability.
- Remaining risks: GAP-06 remains open; runtime conformance and hardware evidence remain outstanding. ADB native receipt storage does not make the device operation atomic.

## 5. Revision history

| Revision | Owner | Reason | Notified ends |
| --- | --- | --- | --- |
| PC-20261105-native-ssh-adb | Coordinator / contract owner | Freeze imported SSH/SCP and Android ADB contracts against launsion `main`; preserves the existing channel and exec envelopes. | Swift host, TypeScript Worker, Android device integration |
| 7eff4567 | Coordinator / integrator | Implemented the frozen contract in the import branch; hardware and runtime verification remain unrun. | Same affected ends |
| android-ssh (ws/android-ssh) | Android implementer | Android end of SSH/SCP: `accelerator:ssh`/`accelerator:scp` registered in `:app` (JSch + Bouncy Castle), Keystore credentials, pinned host keys, Settings → SSH 主机 (`ssh-settings` mapped). Kotlin `ToolSet`/`HostCapabilities` accept the channel.md §4.1 names `ssh`/`scp`/`adb`; `EXEC_CTL cancel` reaches a `CancellableTool`. No frame, field, schema or golden changed; ADB stays iOS-only. Evidence in the commit message. | Android host; Worker unchanged |
