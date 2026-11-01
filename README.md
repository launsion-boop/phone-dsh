<p align="center"><img src="docs/assets/logo.png" alt="Phone DSH" width="200"></p>

# Phone DSH — Jointly open-sourced by Xiaozhi & Tono AI Team

Run DeepSeek Harness, unmodified, on your iPhone.

[简体中文](README.zh.md) · [Architecture](docs/architecture.md) · [Protocol spec](spec/v1/README.md)

<p align="center"><img src="docs/assets/screenshot-chat.jpg" width="300" alt="Phone DSH generating a PDF and reporting progress in the native chat"></p>

> The mascot is fan artwork of the DeepSeek assistant character, used as project branding. It is not an official DeepSeek asset, it is not covered by the MIT licence (see [NOTICE](NOTICE)), and this project is not affiliated with DeepSeek.


## What this is

DeepSeek Harness (DSH) ships a `webworker-runtime` that executes the harness inside a Web Worker. Phone DSH is the host side: a Swift SDK that boots that Worker in the system WebKit engine (WKWebView) and provides the services a phone can honestly offer. The parts a WebView cannot own stay in the app process: the log, the origin, the credentials and the lifecycle.

The pinned release is in [`plugins/dsh-pin.json`](plugins/dsh-pin.json): DSH `0.2.1-rc.2`, commit `7be5505b0be06009d74891c869063c9cf19a0df0`. No DSH source tree is copied, vendored or modified. The Worker image is built from that checkout by driving DSH's own packer library from `plugins/scripts/pack-image.mjs`, with this repository's plugins staged beside it. The packer normalizes exactly two built `dispose()` cleanup call sites in two packages; each site is anchored and hashed in `sizes.json`, and `scripts/ci/no_dsh_patch.py` enforces the source boundary.

Without this split, the official DSH plugin tree (model adapters, tools, sub-agents, session persistence) would have to be reimplemented for a phone, or the phone would have to hand a WebView authority it cannot keep.

## Key properties

- **One loopback origin.** Page, static assets, image and overlay shards, the ordered WebSocket, `/v1/http` and the MCP endpoint share one `127.0.0.1` origin. The Worker uses ordinary same-origin `fetch` and a normal WebSocket; there is no custom URL scheme and no second server.
- **Durable workspace writes.** Every mutation the model makes is numbered with a persistent `mseq`, appended to a write-ahead log and acknowledged before it counts as durable. After a reconnect or restart the Worker replays from the last acknowledged number. Level 1 survives a process kill; level 2 (epoch close, `F_FULLFSYNC`, atomic manifest) puts an epoch on stable storage, so a power loss costs at most the unclosed epoch.
- **The API key never enters the Worker.** The model gateway asks the app's `CredentialProvider` for a credential scoped to the exact upstream host and path, injects it on the host side, and first strips inbound `authorization`, `proxy-authorization` and `x-pdsh-*` headers. The Worker only ever holds a placeholder. A redirect is re-credentialed only within the same scope.
- **Lifecycle the OS can interrupt.** Planned restarts at tool-call boundaries, background park/drain/resume with a 20 s drain window, memory and thermal budgets, and a handoff/reclaim facade backed by a durable non-secret intent. The host state machine fails loud and never silently reopens admission.
- **Self-built accelerators: xz-shell.** The read-only accelerators are our own Rust workspace (`shell/`), not a bundled external binary: ripgrep-compatible search, jq-compatible filters, tree-sitter parse/query and the `phone`/`ctx` host bridge, behind a hand-written C ABI (`include/xzshell.h`) that is linked as `PDSHShell.xcframework`. The same workspace also produces the WASI jq engine the Worker runs. Every command is read-only by construction (a mount-table sandbox rejects anything outside `/dsh/workspace` and `/dsh/home`), bounded in output, and cancellable.
- **Executor inversion.** `bash`, `git`, `python3` and the file tools run inside the Worker on the in-memory VFS, so their writes are ordinary workspace mutations. Only read-only accelerators (`rg`, `jaq`/`jq`, `ts-parse`, `ts-query`, and `phone`/`ctx` when a bridge exists) cross into the app process, and only when the host advertised them.

## Architecture

```text
┌───────────────────────────────────────────────────┐
│ iPhone app (one process)                          │
│                                                   │
│ Swift host: PhoneDSHHost                          │
│  ├─ LoopbackServer   127.0.0.1, one origin        │
│  ├─ WorkspaceLog     WAL + materialized copy      │
│  ├─ ModelGateway     credentials, SSE, retry      │
│  └─ Controller, WebEngine, ExecProvider           │
│                │                                  │
│                │ loopback HTTP + ordered WS       │
│                ▼                                  │
│ WKWebView (web process)                           │
│  └─ Web Worker                                    │
│      └─ DSH webworker-runtime                     │
│          ├─ in-memory VFS (authority)             │
│          ├─ bash, git, python3, file tools        │
│          └─ capability manifest                   │
└──────────────────────┬────────────────────────────┘
                       │ /v1/http, host-injected key, allow-list
                       ▼
                model provider (DeepSeek, ...)
```

The app and the Worker meet at one origin. The page and static assets are served over HTTP; side effects travel over one ordered binary WebSocket (`VFS`, `EXEC`, `JOURNAL`, `API`, `LIFECYCLE`, `CONSOLE`, `FENCE` and the rest); model and MCP traffic goes to `/v1/http`, the only path that leaves the device. The WAL is the recovery log, never a second writer: while the Worker runs, its in-memory VFS is the authority. See [docs/architecture.md](docs/architecture.md) for the persistence model, the frame contract and the failure modes.

## xz-shell

The accelerators the Worker is allowed to hand to the app process are a Rust
workspace of our own, in [`shell/`](shell/README.md). Nothing is generated or
copied into the Apple build: `pdsh-ffi` exports a hand-written C ABI
(`shell/include/xzshell.h`, checked against the exports by a test) and the
Swift host links `PDSHShell.xcframework` built by `shell/build-apple.sh`.

| Crate | What it provides |
|---|---|
| `pdsh-core` | mount-table path sandbox, read-only VFS, cancellation, bounded output, limits, host bridge, command registry and capability JSON |
| `pdsh-rg` | `rg`, ripgrep-compatible read-only search |
| `pdsh-jaq` | `jaq` and its `jq` alias |
| `pdsh-ts` | `ts-parse` and `ts-query` (tree-sitter) |
| `pdsh-phone` | `phone` and `ctx` host-bridge accelerators |
| `pdsh-all` | the complete production registry the host advertises |
| `pdsh-jaq-wasm` | the jq-compatible engine the Worker runs under WASI |

It is deliberately **not** a general shell: `bash -c` and every command that can
write the workspace stay inside the Worker, and the host advertises only the
names it can actually execute. The opt-in link keeps that boundary visible:
build with `bash shell/build-apple.sh` and link with `PDSH_WITH_XZSHELL=1`;
without the artifact the SDK advertises no accelerators at all.

## Quick start

All commands run from the repository root unless stated otherwise.

### Requirements

| Requirement | Notes |
|---|---|
| Xcode 26 with a Swift 6.3+ toolchain | recorded builds use Xcode 26.5 and Swift 6.3.2 |
| XcodeGen | `brew install xcodegen`; regenerates `examples/probe-app/PhoneDSHProbe.xcodeproj` |
| iOS 17+ (the SwiftPM package also builds for macOS 14) | `project.yml`, `Package.swift` |
| Node.js ≥ 22.19, npm and pnpm | plugins, Worker image, pinned DSH build |
| A DSH checkout at the pinned commit | built locally, never committed |
| Rust stable and Apple targets (optional) | only for the accelerator XCFramework |

### 1. Fetch and pin the DSH checkout

```bash
export PDSH_DSH_CHECKOUT="$PWD/../deepseek-harness"
git clone https://github.com/deepseek-ai/deepseek-harness "$PDSH_DSH_CHECKOUT"
git -C "$PDSH_DSH_CHECKOUT" checkout 7be5505b0be06009d74891c869063c9cf19a0df0
(cd "$PDSH_DSH_CHECKOUT" && pnpm install --frozen-lockfile && pnpm build)

mkdir -p "$HOME/.config/phone-dsh"
echo "$PDSH_DSH_CHECKOUT" > "$HOME/.config/phone-dsh/dsh-checkout"
(cd plugins && npm ci)
node plugins/scripts/dsh-checkout.mjs --verify
```

`--verify` fails when HEAD differs from the pin, when a tracked file is modified, when an untracked file exists under a path the packer reads, or when the build artifacts are missing. `PDSH_DSH_CHECKOUT` overrides the per-machine file; the path is never committed.

### 2. Stage the Worker bundle

`examples/probe-app/Bundle/worker/` is not committed, and the host refuses to start without it.

```bash
bash scripts/ci/build-web-dist.sh --source "$PDSH_DSH_CHECKOUT" \
  --store /tmp/phone-dsh-pnpm-store
examples/probe-app/scripts/copy-bundle-assets.sh \
  --checkout "$PDSH_DSH_CHECKOUT" --force
```

The copy step builds the Worker image, adds the CPython and jq WASI artifacts unless you pass `--without-python` / `--without-jq`, verifies the checkout against the image source, and records provenance. The Web distribution holds the complete DSH page; the app's native surface does not open it.

### 3. Build and run the probe app

```bash
cd examples/probe-app
xcodegen generate

# Simulator
xcodebuild -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO

# Device: replace the placeholder bundle id in project.yml first,
# then sign with your team.
xcodebuild -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

The generated `PhoneDSHProbe.xcodeproj` is intentionally not committed. Simulator reports are labelled `ios-simulator` and are not device evidence.

### 4. Run the gates

```bash
bash scripts/ci/check.sh --list
bash scripts/ci/check.sh --only phone-plugins,phone-image,phone-sdk
bash scripts/ci/check.sh        # every stage
bash scripts/ci/smoke.sh        # desktop, real WKWebView, scripted model
bash scripts/ci/sim.sh          # iPhone 17 Pro simulator, four gated JSON reports
```

Stages are `phone-spec`, `phone-plugins`, `phone-image`, `phone-sdk`, `phone-no-dsh-patch`, `phone-hygiene`, `phone-license`, `phone-modules`, `phone-gate-contracts` and `phone-xcode-resolve`. A skipped optional stage makes the run exit `INCOMPLETE` (exit 2), never `PASS`. The catalog-driven real-model batch is separate:

```bash
eval "$(node scripts/ci/model-env.mjs)"   # exports PDSH_MODEL_*, prints no key
bash scripts/ci/scenarios.sh --upstream real
```

## Repository map

| Path | What lives there |
|---|---|
| `Sources/PhoneDSH*` | Swift host modules: `Wire`, `Log` (WAL), `Loopback`, `Gateway`, `Controller`, `Engine`, `Shell`, `AgentCore`, and the `PhoneDSH` facade |
| `plugins/` | Worker-side TypeScript: entry, channel client, DSH plugins, phone profile, image packer, `dsh-pin.json` |
| `spec/v1/` | Host/Worker contract: frames, WAL, exec, handoff, budgets, golden vectors |
| `shell/` | xz-shell: our Rust read-only accelerators, built into `PDSHShell.xcframework` |
| `examples/probe-app/` | iOS probe app, simulator suites, device report export |
| `Tests/` | Swift unit, probe, kill, smoke and scenario suites |
| `scripts/ci/` | Local gates: `check.sh`, `smoke.sh`, `sim.sh`, `scenarios.sh`, `probes.sh` |
| `docs/` | Architecture, probe runbook, native validation records, functional test plan |

## Documentation

- [docs/architecture.md](docs/architecture.md): implemented capabilities, persistence model, credentials, budgets and known limits.
- [docs/functional-test-plan-2026-10-28.md](docs/functional-test-plan-2026-10-28.md): native-surface test matrix (Chinese).
- [docs/runbook-probe.md](docs/runbook-probe.md): build the artifacts, run the probe package and the smoke, read the reports.
- [spec/v1/README.md](spec/v1/README.md): the normative host/Worker contract and golden vectors.
- [CONTRIBUTING.md](CONTRIBUTING.md): the rules a change has to satisfy.

## Security and privacy

- **Keys.** The SDK's model-settings store keeps model credentials in the Keychain through `KeychainModelProviderSecretStore` (`kSecClassGenericPassword`). MCP header values, the independent web-search key and the handoff reclaim token each have a dedicated Keychain service. The per-launch loopback token stays in memory.
- **Egress.** The gateway allow-list is the union of `allowedModelHosts` and `egressAllowHosts`; an empty model list denies every upstream. MCP access is granted per exact scheme/host/port/path, never `*`. The Worker never opens an outbound socket of its own; every external request goes through the host's `/v1/http` and is checked there.
- **What leaves the device.** Prompts, tool results and model requests go directly from the phone to the provider you configure; there is no relay service. Requests to MCP servers you add go to those servers. Workspaces, the WAL and session records stay in the app container under `Library/xl/<workspace_id>/`. The example app sets `DSH_TELEMETRY_DISABLED=1` for the Worker, and this repository adds no analytics or crash reporting.
- **What does not leave.** The API key, the loopback token, MCP header values and the reclaim token are injected by the host. The Worker sees placeholders only. MCP auth headers are injected for the exact URL and redacted from host-managed error bodies.

There is no `SECURITY.md` in the repository yet. To report a vulnerability, use GitHub's private security advisory flow: **Security** tab → **Report a vulnerability**. Do not open a public issue containing a key, token or exploit.

## Status and limitations

A PASS belongs only to the source commit, built artifacts and environment named in its receipt. This tree does not include a current-source receipt for the end-to-end gates.

| Area | Status |
|---|---|
| Desktop smoke (real WKWebView, scripted model) | historical gate on an earlier revision; a rerun on the current source is not recorded here |
| iPhone 17 Pro simulator gate (`sim.sh`) | historical simulator gate; simulator evidence only |
| Full 56-scenario real-model batch (`scenarios.sh`) | NOT_RUN on the current source; needs a real key and a source-bound receipt |
| Physical iPhone (signing, install, real provider, background) | NOT_RUN; no device evidence, so throttling, JIT, jetsam, Lockdown Mode and background scheduling stay NOT_VERIFIED on device |
| Remote handoff peer | facade and in-process tests exist; a deployed remote DSH peer over real transport is NOT_RUN |
| Hosted GitHub Actions | currently off (billing), so no CI badge is shown; `.github/workflows/ci.yml` is kept and the same gates run locally |
| Complete DSH Web UI in the app | removed: the app ships only the native SwiftUI shell; the Worker image still carries the DSH page the Worker boots from |
| Native accelerators | opt-in: `PDSH_WITH_XZSHELL=1` plus a built `shell/dist/PDSHShell.xcframework`; without it the SDK advertises nothing and fails loud |
| Lockdown Mode | the local Worker is disabled and reported; there is no in-app workaround |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Zero DSH source patches is a hard rule; contract changes update `spec/v1` and the golden vectors together; every change keeps the local gates green.

## License

MIT. See [LICENSE](LICENSE). © 2026 Xiaozhi & Tono AI Team.

Third-party components in the Worker image are listed in [plugins/THIRD_PARTY.md](plugins/THIRD_PARTY.md) and [shell/THIRD_PARTY.md](shell/THIRD_PARTY.md). This is a community project, not affiliated with or endorsed by DeepSeek.
