# @phone-dsh/dsh-feature-admin

> **Integration status (this snapshot).** The workspace/profile row and the
> browser page-asset build are wired. The packer bundles the official
> `plugin-manager/src/patch.ts` source from the verified checkout and appends
> the shipped `presets/*.patch.yml` declarations, so the preset roster is real.
> The module still has host typecheck diagnostics tracked in
> the internal blocker list; those are owner work, not stubs.

MIT. Phone-only management of capabilities that are already installed in the
running DSH image. It never installs, removes, updates or resolves a package,
and it never invents a plugin row, skill or agent preset.

## Exports

| Face | Source | Role |
|---|---|---|
| `.` | `src/index.ts` | Host plugin. Registers the `phone/featureAdmin` Typert Remote (`featureAdmin` service, `phone` namespace). |
| `./client` | `src/client/index.ts` → `lib/client.js` | Browser plugin. Registers one `settings.plugins.tab` tab into DSH's shipped Plugins settings section. |
| `./cordis.patch.yml` | `cordis.patch.yml` | Optional direct package-patch row for consumers that resolve it through this package. |
| `./package.json` | — | `dsh.client` declares `platform: web`. |

The package is dual-face: one Loader row naming
`@phone-dsh/dsh-feature-admin` mounts the Host half, and the browser module
system reads the same manifest's `dsh.client` declaration.

`exports["./client"].default` is `./lib/client.js`, because DSH's module table
resolves that exact `default` string to the built page asset and serves its
bytes; it does not transpile TypeScript there. The `types` condition points at
`src/client/index.ts` so workspace typecheck still sees the source face. Build
entry `src/client/index.ts` to `lib/client.js` (or a matching
`lib/client.*.js` chunk) before staging the image.

The manifest declares only concrete export targets. It deliberately has no
`./src/*` wildcard: the image ships built faces under `lib/`, never the source
tree, and a wildcard would be copied as the literal path `src/*` by the stager.

## Host contract: `phone/featureAdmin`

Every method returns `FeatureAdminResult<T>`:

```ts
type FeatureAdminResult<T> =
  | { ok: true; value: T }
  | { ok: false; code: 'unsupported' | 'invalid-request' | 'not-found' | 'conflict' | 'io-error' | 'internal'; reason: string; domainCode?: string }
```

| Method | Arguments | Real source |
|---|---|---|
| `pluginList` | none | DSH `pluginInventory.list()`. The result adds `platform`, `management` and a per-row `readOnlyReason` for the default-protected shipped namespaces; it does not re-derive inventory. `management.available` is false with an explicit reason when either the Host inventory or `profileContext` cannot provide a persistent write target, so the page disables switches instead of failing after a click. |
| `pluginSetEnabled` | `entryId`, `enabled` | DSH `writePluginEnabled(profileContext, entryId, moduleName, enabled)` from `@deepseek-ai/dsh-plugin-manager/src/patch.ts`. The whole inventory-read → layer-choice → write → compose-check → repair cycle holds `withFileLock(join(profile.dir, 'package.json'))`, the same lock file the official plugin manager and config editor use, so concurrent toggles cannot lose one another's patch. Before either layer is written, that lock holder snapshots the profile and home patch bytes; a repair write, composition read or final verification failure atomically restores both files, so a reported failure leaves the next boot unchanged and cannot overwrite another toggle's committed row. The write is atomic and preserves comments, unrelated overrides and `!!js`; the result carries `restartRequired` and the exact `patchPath`. When the entry is introduced or overridden by the home layer (`$DSH_HOME/cordis.patch.yml`, which DSH applies after the profile patch), the same writer targets that layer so the toggle is not skipped as an unknown id on the next boot. The official writer's implied check only combines bundle layers with the file it edits, so the Host then recomposes bundle+profile+home+overlays; if an earlier profile override still wins, it writes an explicit home-layer switch and verifies the effective state again. Protected management rows return `conflict` and are never written. |
| `skillsList` | none | Flat regular `.md` files directly under `/dsh/home/skills`. |
| `skillsRead` | `name` | One flat `.md` after root/realpath/symlink checks. |
| `skillsWrite` | `name`, `content` | Atomic same-directory temp+rename, then invalidates the live `ctx.skills` catalog. |
| `skillsDelete` | `name` | Unlink after the same checks, then invalidates the live `ctx.skills` catalog. |
| `agentPresets` | `{ request: { action: 'list' \| 'read' \| 'select', presetId?, sessionId? } }` or flattened `action`/`presetId`/`sessionId` | The official `ctx.agentPresets.remoteExportList()`, `readDocument()` and `select(agent, presetId)`. `select` first requires the `sessionId` to be a member of the real Host-managed Session index (`ctx.sessionController.list()`, or `ctx.sessions.list()` when only the store is mounted) and excludes subagent-origin rows; an unlisted or retained-fallback id returns `session/not-found` without resolving an Agent. |

If `profileContext` is absent, `pluginList` reports
`management.available: false` and `pluginSetEnabled` returns `unsupported` with
that reason. If `ctx.agentPresets` is absent, the `list`, `read` and `select`
actions return `unsupported` and no synthetic roster. If `ctx.skills` is absent
or the mounted registry exposes no real catalog invalidation, a write/delete
returns `unsupported` before touching disk because the slash list could not
re-discover the file.

### Skill path rules

`/dsh/home/skills` is the only root. A name must be a single kebab-case
`*.md` basename. The Host refuses NUL, backslashes, `/`, absolute or `~`
targets, `.`/`..` segments, non-`.md` files, a symlinked root, a symlinked
target, and any resolved path outside `realpath(root)`. Listing skips entries
that are not regular files.

### Catalog invalidation

DSH 0.2.1 exposes no public `ctx.skills.invalidate()`. The Host feature-detects
the registry's own cache invalidation and requires it before a write/delete
touches disk. Emitting `skills/change` alone does not clear the registry's
completed-catalog cache, so there is no event-only success fallback: without
the real invalidator the call returns `unsupported` and the file is unchanged.

## Browser contract

The client uses the page's existing `ctx.connection.rpc` to call
`phone/<method>` on `/api`. That is the same carrier and `phone` namespace the
native management pages already use; there is no second transport, session,
chat protocol or React instance.

The tab registers into `settings.plugins.tab` with id `phone-capabilities` and
order `20`, next to DSH's official read-only inventory tab. Its controls are:

- real inventory rows with a switch that calls `pluginSetEnabled`; rows the
  Host marked `readOnlyReason`, and every row when `management.available` is
  false, render a localized Protected/Unavailable label and no switch, with the
  Host's English reason only in the `title` attribute;
- a localized runtime-phase label for every inventory `fiberPhase`; an unknown
  future phase falls back to a translated `Unknown` label, never the raw token;
- a skill list and Markdown editor that calls `skillsWrite` / `skillsDelete`;
- the official preset roster with composition read and a session select. The
  option list is derived from `SessionListState.ids` (Host-list membership),
  drops dangling rows and subagent-origin rows, and the component subscribes to
  `ctx.sessions.list` through `useSyncExternalStore`, so a retained fallback
  row cannot become a target and the list cannot go stale;
- an always-visible, locale-owned restart notice and platform boundary that
  this Host cannot install package rows. The Host's English technical reason is
  only a `title`, not the zh-CN body copy.

Protection is deny-by-default for the shipped namespaces: every
`@deepseek-ai/*` and `@phone-dsh/*` row is read-only unless it is listed in
`TOGGLEABLE_PLUGIN_MODULES`, the explicit allowlist of optional capabilities
whose absence cannot take the page, its `/api` carrier, or the Agent/skill
services it manages down. The allowlist is deliberately small (for example
`dsh-office-to-pdf`, `dsh-schedule`, `dsh-api-job-controller`,
`dsh-workspace-files`); everything else from those namespaces stays enabled
and survives a future image addition without another audit. Rows from another
namespace remain toggleable because they are not part of this image's
management chain.

The management chain has named reasons and can never be toggled from the page:
`@phone-dsh/dsh-surface-phone`, `@deepseek-ai/dsh-host-webserver`,
`@phone-dsh/dsh-feature-admin`, `@deepseek-ai/dsh-host-plugin-inventory`,
`@deepseek-ai/dsh-api-gateway`, `@deepseek-ai/dsh-typert-registry`,
`@deepseek-ai/dsh-api-remote-access`, `@deepseek-ai/dsh-api-remotes`,
`@deepseek-ai/dsh-api-session-controller`,
`@deepseek-ai/dsh-api-settings-controller`, `@deepseek-ai/dsh-settings`,
`@deepseek-ai/dsh-client-modules`, `@deepseek-ai/dsh-client-connection`,
`@deepseek-ai/dsh-client-locale`,
`@deepseek-ai/dsh-client-ui-layout`, `@deepseek-ai/dsh-client-ui-renderer`,
`@deepseek-ai/dsh-client-ui-settings`,
`@deepseek-ai/dsh-client-ui-settings-plugins`,
`@deepseek-ai/dsh-client-ui-settings-plugin-inventory`,
`@deepseek-ai/dsh-agent-preset-registry`, `@deepseek-ai/dsh-agent`,
`@deepseek-ai/dsh-session` and `@deepseek-ai/dsh-skill`. DSH's own inventory
projection does not carry the plugin manager's `readOnlyReason`, so the package
states this policy itself and enforces it on the Host, not only in the page.
The behaviour test composes the real base plus phone profile patches and fails
if a shipped row is classified as toggleable without an explicit allowlist
entry.

## Integration contract (final integration)

1. Add `phone-feature-admin` to `plugins/package.json` workspaces and to
   `plugins/tsconfig.json` (or the final aggregation project).
2. Insert the phone rows in `plugins/profile/phone.worker.cordis.patch.yml`.
   The feature-admin row is the Host+client package:
   ```yaml
   - id: feature-admin
     name: '@phone-dsh/dsh-feature-admin'
   ```
   The package's local `cordis.patch.yml` is the same row for consumers that
   apply package patches directly. The same profile must mount the official
   preset registry; without it `ctx.agentPresets` is absent and the preset
   section can only report `unsupported`:
   ```yaml
   - id: agent-preset-registry
     name: '@deepseek-ai/dsh-agent-preset-registry'
     config:
       default: standard
   ```
3. Apply the shipped `@deepseek-ai/dsh-web-app` preset patch files to the image
   as bundle/patch layers, in the web bundle's own order:
   `presets/standard.patch.yml`, `presets/ptc.patch.yml`,
   `presets/minimal.patch.yml`, `presets/cordis.patch.yml`. They declare the
   real `@deepseek-ai/dsh-agent-preset` rows that the registry lists and
   selects. Merely mounting the registry without these declarations gives an
   empty roster, not a fake one. Because the phone image does not materialize
   the `dsh-web-app` bundle, final integration must copy or apply these files
   explicitly; it must not copy `web-runtime` or create a second `/api`
   carrier.
4. Build `src/client/index.ts` with DSH's client build face (React external,
   the page's platform module table) to `lib/client.js`. The manifest's
   `exports["./client"].default` must stay `./lib/client.js` (or a matching
   `lib/client.*.js` chunk): DSH's module table treats that path as the page
   asset and serves the exact bytes, so it must not point at TypeScript source.
   It is a browser page asset, not a Worker face; the image packer must keep it
   out of the Worker lowering path. Its resolved image path must be
   `node_modules/@phone-dsh/dsh-feature-admin/lib/client.js` so DSH's
   `PAGE_ASSETS` rule serves it to the page.
5. The host face imports the official
   `@deepseek-ai/dsh-plugin-manager/src/patch.ts` as required. The published
   DSH package ships `lib/` and excludes `src/`, so the image staging must
   bundle that module, `yaml`, and their relative/`@deepseek-ai` dependencies into
   the staged host face (or ship the source face); leaving it as a bare staged
   import would fail to resolve inside the Worker. `scripts/pack-image.mjs`
   keeps every `@deepseek-ai/*` import external today, so this is a required
   final-integration build change, not a runtime fallback this package can
   perform without copying DSH code.
6. The browser row comes from the same manifest's `dsh.client`; do not add a
   second client-only row or copy React into the bundle.
7. Do not add an install/remove/market method. The only plugin mutation is the
   profile/home patch toggle, which takes effect after a Worker restart.

## Tests

```bash
PDSH_DSH_CHECKOUT=/dsh-reference node --test plugins/tests/phone-feature-admin.test.ts
```

The suite uses a real temporary profile (bundle layer + user patch + optional
home layer), the checkout's official `writePluginEnabled`, `loadOverlayPatches`
and `applyEntryPatches`, real files and symlinks under a temporary skills root,
a missing-`agentPresets` context, a real `SessionStore` with attached and
subagent Sessions, a Host `sessionController` catalog over that store, a
Typert `agent` lookup that resumes a cold Session, and a profile+home same-id
override whose switch-only home row the official writer deletes so the repair
branch is exercised. Two `pluginSetEnabled` calls run through `Promise.all` and
must both persist on the official profile lock. A conflicting launch overlay
forces the post-write verification to fail after the official writer and repair
branch ran; the test asserts the failed call returns `conflict`, restores both
patch layers byte-for-byte, and keeps the other concurrent toggle committed. It
also checks the zh-CN row copy (localized protection/phase, reason title-only)
and the manifest `exports["./client"]` page-asset path. It composes the
checkout's real `dsh-base` patch with the phone profile patch and fails when
any shipped row is toggleable without an explicit allowlist entry. It does not
run pnpm, build the browser bundle, boot WKWebView or touch a real DSH home.

## Platform limit

This is not a remote-PC wrapper and not a package installer. On iPhone the
running image is immutable; only the profile patch and the flat user-skill
directory are editable. The page states that boundary on every visit.
