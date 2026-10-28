<!-- SPDX-License-Identifier: MIT -->
# DSH image tooling for the phone Worker path

These scripts pin the DeepSeek Harness (DSH) checkout and build the artifacts the
phone Worker boots from. They never copy or patch DSH source: the packer and the
patch reader are imported from the pinned checkout named by `PDSH_DSH_CHECKOUT`.

Everything here is desktop/CI tooling. No iOS or WebKit behaviour is verified by
this package; the phone path is `NOT_VERIFIED` until the Phase 0 probe package
runs on a device.

## Commands

```sh
# Verify a checkout (default: the canonical pin; the pair below is controlled).
PDSH_DSH_CHECKOUT=<checkout> node scripts/dsh-checkout.mjs --verify

# Same check, machine-readable facts on stdout.
PDSH_DSH_CHECKOUT=<checkout> node scripts/dsh-checkout.mjs --print-json

# Controlled checkout verification: the same clean/build/version rules, with
# an explicit SHA + version pair. The facts keep `pin` (the expected pair) and
# `canonicalPin` (the unmodified dsh-pin.json values) so callers can audit both.
PDSH_DSH_CHECKOUT=<checkout> node scripts/dsh-checkout.mjs --print-json \
  --commit <40-hex> --version <version>

# Pack the Worker image and its runtime artifacts.
PDSH_DSH_CHECKOUT=<checkout> node scripts/pack-image.mjs --out <dir>
# The explicit path overrides only the path. The checkout is still verified
# (HEAD, clean tree, built artifacts, installation version), and sizes.json
# records the verified HEAD as `dsh_commit` beside `dsh_pin_commit`.
node scripts/pack-image.mjs --out <dir> --checkout <checkout>

# Controlled release override: an explicit SHA + version pair. Both are
# required, the checkout must match them, and sizes.json records the actual
# commit/version beside the canonical dsh-pin.json values.
node scripts/pack-image.mjs --out <dir> --checkout <checkout> \
  --checkout-sha <40-hex> --checkout-version <version>

# Pack an uncompressed data overlay (only home/ and workspace/).
node scripts/pack-overlay.mjs <dir> --out <file.tar>

# Tests (Node discovers the directory entry added for `--test <dir>`).
node --test scripts/
```

`--verify` exits 2 on usage errors and 1 on a verification failure. The pin is
`dsh-pin.json`: repository, full 40-character commit, and version
`0.2.1-rc.2`. A checkout is clean when it has no tracked modifications and no
untracked file under a root the packer reads (`apps/`, `native/`, `packages/`,
`vendor/`). The packer indexes workspaces from the live filesystem and honours
package `files` allowlists, config trees, and the installation manifest, so an
untracked file there can enter the image while HEAD still matches the pin.
Untracked scratch outside those roots cannot affect the image; it is reported
in `--print-json` as `untrackedOutsideImageRoots` and does not fail the check
(the machine's pinned checkout carries unrelated top-level documents).

`scripts/ci/build-web-dist.sh` calls this verifier before cloning and before
`pack-image.mjs` sees the checkout. Its `--commit`/`--version` pair has the same
meaning as `--checkout-sha`/`--checkout-version`, and its `web-build.json`
records both the actual commit/version and the canonical pin. The copy step
requires that record and the image's `sizes.json` to name the same commit and
installation version.

## Environment variables

| Variable | Used by | Meaning |
| --- | --- | --- |
| `PDSH_DSH_CHECKOUT` | checkout verifier, image packer, profile tests | absolute path of the DSH checkout; never written into the repository |
| `PDSH_DSH_PORT` | Worker runtime | surface-phone loopback port; `0` picks an ephemeral port |
| `PDSH_DSH_LAUNCH_TOKEN` | Worker runtime | launch token for the resident surface |
| `PDSH_CHANNEL_URL` | Worker-entry host (W1) | loopback URL of the ordered WebSocket channel |
| `PDSH_CHANNEL_TOKEN` | Worker-entry host (W1) | per-boot bearer token for that channel |

The channel names are reserved by the worker profile
(`profile/phone.worker.cordis.patch.yml`) and are documented there. The W1
worker entry provides them and the W1 plugin transport rewrite consumes
`globalThis.__PDSH_CHANNEL__`; the W0 profile keeps the desktop bridge rows as-is
because plugin transport changes are outside this work package.

## Outputs of `pack-image.mjs`

| File | Contents |
| --- | --- |
| `image.tar.gz` | the gzip-compressed ustar base image returned by `packVfsImage` |
| `lazy/<sha256>.tar.gz` | lazy page-chunk archives returned by the packer (empty for the phone roster) |
| `manifest.json` | verbatim copy of the image's `config/vfs-manifest.json` (`root`, `profile`, `installation`, lowering contract, lazy table) |
| `worker.js` | runtime Worker assembly copied from the checkout's `webworker-runtime/lib/worker.js` |
| `client.js` | runtime page-side tunnel client copied from `webworker-runtime/lib/client.js` |
| `sizes.json` | `{raw_bytes, gzip_bytes, lazy:[{name,bytes}], files, client_roster, dispose_compat, built_at, dsh_commit, dsh_version, dsh_pin_commit, dsh_pin_version, dsh_expected_commit, dsh_expected_version, dsh_checkout_overridden, dsh_checkout}` |
| `phone-dsh-provenance.json` | phone source hash, pinned DSH commit, Python capability, and SHA-256 for every file in the final bundle |

`client_roster` records every packed `dsh.client` browser bundle, the
`window.__DSH_BOOT__` rows DSH's own client-modules host half composed from
those exact image bytes, and the connection contract: the official `connection`
row is present for its browser bundle only, its host half stays pending, and
`phone-surface` remains the one host `ctx.connection` and `/api` owner.


`raw_bytes` is the uncompressed tar length (the image's on-mount size), `files`
is the number of base-image entries, and each lazy `bytes` value is the
compressed archive size. The packer normalizes gzip metadata (no build time,
operating-system byte set to "unknown"). Build time never enters the archive;
the staging directory's name can appear in the debugger `sourceURL` comments of
the staged packages, so compare image file contents rather than raw bytes when
staging on different machines.

The probe app assembles a second provenance record after applying its
JavaScriptCore prelude. It records every final bundle file by relative path and
SHA-256, including `index.html`, `boot.js`, the Worker entry, image, manifest,
optional runtime files, and lazy shards. The provenance sidecar excludes itself
to avoid a hash cycle.
Reused or cached assets must pass `verify-bundle.mjs`; use
`--without-python` only when intentionally building an app image without the
Python interpreter. Low-level image tests may still omit Python explicitly in
their packer options.

## Why the packer needs a staging wrapper

The official packer applies `EXCLUDE_WORKSPACE` to every package passed through
`PackOptions.workspaces`, dropping `src/**` and `dist/**` from workspace
packages. The six phone-dsh plug-ins publish TypeScript entry points from
`src/` and have no `lib/`, so passing their source directories straight to the
packer would produce empty packages (and unresolvable export faces).

`pack-image.mjs` therefore stages each plug-in in a temporary directory first:

1. every code export face is bundled with esbuild (ESM, platform `node`,
   target `node22`) into `lib/<face>.js`; all bare package imports
   (`@deepseek-ai/*`, `@phone-dsh/*`) and `node:*` imports stay external;
2. non-code export faces (`cordis.patch.yml`, `package.json`) are copied
   verbatim;
3. the staged `package.json` keeps the package identity and dependencies but
   rewrites `main`/`exports` to `./lib/...`; the source publish allowlist is
   removed because the staged tree contains exactly the files to ship;
4. the staged directories — all six, including `surface-phone` — are passed in
   the `workspaces` map. The temporary directory is deleted after the pack.

The staging step also records every `@deepseek-ai/*` import in the bundled
output and adds it to the roster, so a workspace package's runtime imports are
materialized even when the source manifest's peers are incomplete.

Two `./client` faces have opposite destinations. A package declaring
`dsh.client.platform === 'web'` is a browser page asset: the stager builds its
entry (the `types` source condition when the manifest already points `default`
at the built `lib/client.js` the DSH module table serves) into `lib/client.js`,
which the official `PAGE_ASSETS` rule ships **without** the Worker lowering
transform. `@phone-dsh/dsh-exec-bridge`'s `./client` face is the opposite: it is
a Worker-importable module (the W1 exec transport). Staging it as
`lib/client.js` would reproduce the page-asset rule and ship an ESM body the
Worker rejects, so the stager maps that face to `lib/client-module.js` (the
package's `exports` entry carries the path, so importers are unaffected).
Only concrete export targets are staged: a `./src/*`-style wildcard names a
source tree the image does not ship, so phone packages must not declare one.
After packing, `pack-image.mjs` requires every enabled `dsh.client` row's real
bundle to be a non-empty page asset, and asks the checkout runtime's
`lowerModuleSource` to re-lower every other packed plugin `.js` face: an
already-lowered body rejects the second pass, a still-ESM body lowers
successfully and fails the build, and an already-CommonJS body needs no pass. A
future face named `client` or `client.*` cannot regress silently.

## Cordis disposal compatibility

`Fiber.dispose` is typed `() => Promise<void>`, but Cordis's effect wrapper
returns `undefined` once the fiber was already disposed. The pinned
`tool-subagent` and `file-reference-local` `agent/disposed` listeners call
`fiber.dispose().catch(...)`, so a child Agent whose scope already disposed the
fiber makes that listener throw `TypeError: ... reading 'catch'` (observed on
the real iPhone WebWorker after a successful workflow). The checkout cannot be
patched, and normalising every fiber would change Cordis globally.

`dispose-compat.mjs` therefore stages only those two built packages and
rewrites exactly one call statement in each to
`Promise.resolve(fiber.dispose())...`. The call still happens synchronously on
the same `this`, a rejection still reaches the existing listener, and
`file-reference-local` keeps adding the normalised promise to `promptDisposals`
until it settles. Each site names its package, file, enclosing declaration and
exact statement; a missing or duplicated match fails the pack instead of
guessing, and `sizes.json` records the pinned commit/version and the source and
transformed SHA-256. The pinned checkout itself is never modified. Because the
staged copies live under `tmpdir()`, each also carries a `node_modules` view
that links every declared dependency and peer to the pinned workspace or install
directory; the packer's collector skips those links, so they restore the same
resolution the checkout has without changing image contents. The behaviour
tests load the real built packages and drive their actual listeners with a real
Cordis fiber, a rejecting disposer and a deferred disposer; the integration test
runs the pinned packer's `packVfsImage` over a `tmpdir()` stage and asserts no
missing packages and both transformed statements in the image.

## Roster and profile

The image's roster is the 0.2.1 `@deepseek-ai/dsh-base` bundle, every package its
patch rows name, the six phone-dsh packages, every package named by
`profile/phone.worker.cordis.patch.yml`, the Worker assembly's literal image
entry seeds (`dsh-app-boot`, `dsh-cmdline`, `dsh-launch-environment`, `cordis`,
and the Cordis boot plugins), and the staged plug-ins' external imports.

The image records the shipped profile template name `web`, because the Worker
host passes the web command line (`--host 127.0.0.1 --port <n> --no-open`). The
`@deepseek-ai/dsh-web-app` bundle and `web-runtime` are deliberately **not**
materialized and its `dsh-headless` sibling is not used either: the resident
surface is our `surface-phone`, which supplies `ctx.connection`, token/cookie
authentication, `GET /`, `/api`, and the `XL_DSH_READY` announcement.

The image *does* carry the complete browser client roster from the web-app
layer: `@deepseek-ai/dsh-client-modules` (whose node half composes
`window.__DSH_BOOT__` and serves `/plugins/<id>/client.js`), the official
`@deepseek-ai/dsh-client-connection` browser bundle, and the UI rows for the
mobile workbench, chat, sidebar, document/file/browser/terminal tabs,
directory picker, settings, references, jobs, schedule, plan and the rest. The
home patch inserts the host rows those clients call (`dsh-api-remotes`,
`dsh-api-session-controller`, `dsh-client-file-upload`, `dsh-workspace`,
`dsh-workspace-files`, `dsh-message-feedback`, `dsh-session-reference`,
`dsh-file-reference-local`, the session projections, `dsh-office-to-pdf` and
the browse directory-picker backend) beside the `phone-surface` row.

The `connection-browser` row is a browser-bundle carrier only. It injects
`webStartup`, which this image never provides, and `credentials` stays disabled,
so its host half cannot activate; `phone-surface` remains the only host
`ctx.connection` and `/api` registration. The row deliberately avoids the
global `connection` id because app-boot requires that id to activate. The
terminal controller's host half activates over `subprocess-xl`, but that phone
provider has no terminal primitive and rejects `spawnTerminal`; the terminal tab
stays in the roster while its operations fail with that real error, and no
process or PTY is simulated. Office conversion likewise keeps the tab and
reports the runtime's `libreoffice-kit` `unavailable` error rather than
returning an empty PDF. No additional `@deepseek-ai/dsh-web-app` row is
required by this boot path; the one bundle the template names but the image
does not carry is reported by DSH's app-boot as a skipped bundle and is
expected.

`pack-image.mjs` asserts the roster structurally: every enabled `dsh.client`
row's real browser bundle must be present and still a page asset, DSH's own
client-modules host half must compose `window.__DSH_BOOT__` from those exact
bytes, and the connection/account rows must match the contract above.

The home patch is loaded with DSH's own `loadOverlayPatches`, which is the same
reader a profile boot uses, so `!!js` expressions keep their in-memory
`__jsExpr` form when the packer writes `home/cordis.patch.yml`. The packer's
`platformHomePatch` helper composes the shipped web-app template, which this
image deliberately does not carry, so the phone home layer comes from
`profile/phone.worker.cordis.patch.yml` instead. The wrapper still enforces the
`PLATFORM_ENTRY_CONFIG` requirement the same way: the active JSONL store
(`session-persistence-journaled`) must mount with `compression: none`, because
the Worker has no Zstandard writer for its own session log.

## Overlay rules

`pack-overlay.mjs` accepts only `home/` and `workspace/` at the top level,
rejects symlinks and special files anywhere in the tree, and writes a ustar
archive with byte-wise sorted paths, normalized modes, and mtime 0. File bodies
are streamed; only the path list is retained in memory.
