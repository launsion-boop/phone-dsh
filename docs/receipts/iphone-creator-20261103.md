# iPhone Agent Creator — PR26 follow-up

Base: `edb6c419b0ab5b4bf3d46ca8a59dc4a3957ccf1b`.
Branch: `codex/iphone-settings-fix-20261103`. PR14 is not changed here.
[Behavior contract](../design/iphone-creator-contract-20261103.md).

## Implemented behavior

The native entry opens a real, healthy `cordis` session and dismisses the whole
settings sheet and compact drawer. It sends no task and does not elevate access.
The old session's unsent draft is preserved. The user types and submits the
creation request in the new session; ordinary DSH profile-operation approval
still applies.

The Worker mounts the official `CordisInspectRegistryService` and official Host
Config/Service/Event/Tool providers. Only the read-only inspector is mounted;
the desktop VM runner is not advertised as available. Phone authoring guidance
is scoped to Creator sessions, rather than added to ordinary chat prompts.

`PhoneCreatorManager` preserves the existing `pluginManager` service/methods and
`ChangeResult` contract. It implements offline installation of declarative
Agent preset bundles using the modules already present in shipped presets:

1. The user-requested task authors `package.json` and `cordis.patch.yml` under
   the workspace. Inspection and filesystem tools execute normally.
2. The installer validates real paths, regular UTF-8 files (512 KiB each), the
   package and declaration identities, module availability and ownership.
   Dependencies, lifecycle scripts, arbitrary JS, `!!js`, Host-row overrides and
   shipped namespace replacement are refused with an existing management error
   and an actionable diagnostic. npm/Git/tarball installation remains a desktop
   capability.
3. The installer keeps an owned copy under the profile's `node_modules`, writes
   the existing profile manifest format under the official profile lock, and
   calls the official profile recomposition path. An `applied` result requires
   a real healthy roster entry and a resolvable preset, not just a successful
   file write.
4. A rejected load restores the original profile/owned file bytes. Cancellation
   before publication restores state, and its existing request identity can be
   queried through the official RPC. A request after publication is too late to
   cancel. Owned bundles support enable/disable; destructive removal is refused
   explicitly. A disabled bundle must be enabled before its custom sessions can
   be resumed.

The original blocker also exposed a Worker metadata lookup gap:
`createRequire(...).resolve.paths()` only returned the immutable image root.
The existing `node:module` shim now exposes Node ancestor metadata search paths,
which lets app-boot find profile-local manifests/YAML. Executable module loading
still uses the pinned image loader; the change does not load new JS packages.

No DSH source patch, new RPC endpoint, wire field, error code, database migration
or default permission/preset change is introduced. Built-in sessions and their
formats remain unchanged. Older images without the metadata lookup correction
retain these files but cannot discover the new local bundles; custom sessions
need the corrected image to compose. No silent default-preset substitution is
used on rollback.

## Execution evidence

- Before the change, the real packed-image regression failed because `cordis`
  lacked `cordisInspect` and `pluginManager`.
- Real packed Worker: inspector queries, filesystem writes, local installation,
  roster/YAML readback and custom-session projection **PASS**. A separate OS
  process/Worker boot loaded the three actual saved profile/bundle files and
  composed the custom preset. Model requests at entry and before an explicit
  prompt remained **0**.
- Real failure paths: incompatible bundle admission restored the original file
  bytes; external package requests were refused; queued cancellation and RPC
  recovery returned `cancelled` without changing files. Real filesystem tests
  rejected escaping source links, destination links, lifecycle scripts,
  unavailable modules, `!!js` and malformed dependency fields. Focused tests:
  **29 passed, 0 failed, 0 skipped**.
- Real macOS WKWebView + Worker + Agent loop with a scripted local model:
  **PASS**. Entry made no model request; an explicit test prompt then executed
  the inspection/write/install tools. Both authored and installed files were
  independently read from host materialization. A planned restart reconstructed
  the Worker from durable state, read back the YAML and created a session with
  `agentPreset=wk-created-review`. This is scripted-model evidence, not a
  real-provider quality or physical-iPhone result. Full smoke: **4 passed**.
- Native iPhone 17 Pro / iOS 26.5 Simulator, no preview or automatic prompt:
  **PASS** for `cordis` projection, full sheet dismissal, idle new input and
  restoration of the old unsent draft. Existing dark/reopen/cold-launch and
  real preset/YAML/non-default selection tests also passed. The first Creator
  UI attempt used an obsolete editor label; the query was corrected to the
  actual native control, without changing the product input behavior.
- SDK: **1452 tests, 5 skipped, 0 failures**. Plugins/typecheck: final run recorded
  below. Image, gate contracts, no-DSH-patch, hygiene/license, spec/cross-tree and
  P0 checks were run. The P0 provenance correction moves only the existing
  “submit answer” source line; no requirement or divergence baseline is relaxed.
- The initial complete plugin run exposed two asynchronous boot-test races.
  Tests now wait for their actual terminal error messages; the redaction and
  exact message-count assertions are retained. The selected 21 entry tests pass.

## Final checks

- Final plugin stage: **2389 tests, 2369 passed, 20 skipped, 0 failed**;
  typecheck passed.
- Final aggregate native UI: **3 tests passed, 0 failures**, including Creator,
  old-draft preservation, dark settings and actual preset/YAML selection.
- Debug/unsigned generic iOS Release compilation: **PASS**.
- Fresh Worker/image assembly and bundle freshness: **PASS**.
- SDK, image, gate contracts, no-DSH-patch, hygiene/license, spec/P0/cross-tree:
  **PASS** across the recorded stage runs. Earlier failures and their fixes
  above are not presented as a successful initial run.

Physical iPhone, data/key-preserving device installation, real-provider preset
authoring, CSV/model-context regression, unplanned power loss and long stress
remain **NOT_RUN**. Simulator/Node/macOS WK evidence does not replace the user's
native device acceptance. Optional Rust shell FFI was not enabled in the app
compilation checks; Creator's tested filesystem path runs in the Worker.
