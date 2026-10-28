# Upstream patch drafts for DeepSeek Harness (W9-UPSTREAM)

These are patch drafts and one pending proposal note for the DeepSeek Harness (DSH)
maintainers, produced for the phone-DSH work package. They are **drafts only**:

- They are **not applied** to the pinned DSH checkout and **not applied** to this
  repository. The zero-DSH-source-patch rule is unchanged: this repository consumes
  DSH only through the pinned checkout named by `PDSH_DSH_CHECKOUT`, and no DSH
  source is vendored or patched here. The image packer's two built `dispose()`
  call-site normalizations are not source; they are described in
  [`plugins/scripts/README.md`](../../plugins/scripts/README.md#cordis-disposal-compatibility).
- Each `.patch` file is a `git format-patch` output generated in a temporary clone of the
  pinned checkout (DSH `0.2.1-rc.2`, commit
  `7be5505b0be06009d74891c869063c9cf19a0df0`). The temporary clone was discarded;
  the pinned checkout was never written.
- Each draft was verified with `git apply --check` against the pristine pinned
  checkout and applied cleanly in a fresh clone. The DSH test suites were **not**
  run from this repository (the checkout's dependency tree is not installed here);
  the commands below are what the drafts' tests run in DSH CI. A later DSH master
  may need a rebase; regenerate from a temporary clone rather than editing these
  files.

| Patch | Subject | Touches |
|---|---|---|
| `0001-worker-host-pass-sink.patch` | `feat(webworker-runtime): let createWorkerHost install a VFS sink` | runtime assembly, runtime test tree, runtime exports |
| `0002-overlay-merge-home-patch.patch` | `fix(webworker-packer): keep platform rows when an overlay ships a home patch` | packer, packer test tree, packer exports |
| `0003-ios-webkit-acceptance.patch` | `test(web): boot the packed worker deployment in WebKit` | web preview acceptance |

The three drafts touch disjoint files and do not depend on each other; they apply
in any order. From the phone-dsh repository root, check without applying with:

```sh
for p in docs/upstream/*.patch; do
  git -C "$PDSH_DSH_CHECKOUT" apply --check "$PWD/$p"
done
```

and apply one at a time with:

```sh
git -C "$PDSH_DSH_CHECKOUT" apply "$PWD/docs/upstream/0001-worker-host-pass-sink.patch"
```

## Pending proposal — Cordis `Fiber.dispose` return value

This is a proposal note, not a generated patch yet. In the pinned
`vendor/cordis/src/fiber.ts`, `Fiber.dispose` is declared
`() => Promise<void>`, but the effect disposer it aliases returns `void` once
the owning fiber has already been disposed. The two DSH `agent/disposed`
call sites normalized by the phone image call `.catch` on that value, so a
second disposal throws `TypeError`. Upstream should choose one contract:

- keep the declared Promise and make the already-disposed branch return a
  resolved promise (`Promise.resolve()`), so every caller may chain; or
- widen `Fiber.dispose` and the effect disposer to `() => void | Promise<void>`,
  document that callers must normalize, and update the two DSH `.catch` sites.

Once maintainers choose a shape, regenerate a `git format-patch` draft from a
temporary clone and add it to the table above. Until then the phone image keeps
the byte-scoped built call-site normalization and leaves DSH source untouched.

## 0001 — `createWorkerHost` passes a VFS sink to `MemoryVfs`

### Motivation

A deployment that mirrors the Worker's in-memory filesystem into a durable store
needs a mutation observer on the mounted `MemoryVfs`. `MemoryVfs` already accepts a
`VfsMutationSink` in its constructor options, but `createWorkerHost` builds the
filesystem itself, so a caller has no seam to supply the sink before boot. The only
alternative today is to obtain `host.vfs` after `start()` and attach an observer,
which is racy for mutations that happen during boot and different from the
sink's ordered, post-commit semantics.

### Behaviour change

`WorkerHostOptions` gains an optional `sink?: VfsMutationSink`. When present,
`createWorkerHost` constructs the mounted filesystem as
`new MemoryVfs({ sink })` and mounts the image and overlays into it. The published
semantics are the ones `MemoryVfs` already documents:

- Image and overlay seeding is silent; only mutations committed after mounting
  reach `record()`.
- `record()` is called after the in-memory commit and does not delay the writer.
  A sink that cannot persist reports the failure itself and stops mirroring; it
  does not reject a write that already committed.
- `host.vfs.flush()` settles every mutation recorded so far. The host does not
  flush implicitly on boot or `stop()`; the deployment chooses its checkpoints.
- The sink sees the whole mounted tree, not a filtered VFS path set. A host that
  persists only some roots applies its own path policy in `record()`.

The package root now also exports `VfsMutation`, `VfsMutationListener` and
`VfsMutationSink`, so the option's callback shape is reachable without a deep
import. Without the option the new code path is `undefined` and the mounted
filesystem is exactly the ephemeral `MemoryVfs` as before.

### Tests

`packages/experimental/webworker-runtime/tests/worker-host-sink.spec.ts` constructs a
host from a small image, asserts that the mounted filesystem carries the supplied
sink, that image seeding produced no record, that one committed write reaches
`record()` with the post-commit mutation shape, and that `flush()` settles the sink
once.

Run it with:

```sh
pnpm exec vitest run packages/experimental/webworker-runtime/tests/worker-host-sink.spec.ts
```

### Risk

- API addition only; the option is optional and existing callers are unchanged.
- Sink ordering follows `MemoryVfs.publish`, so a sink that throws is logged and
  cannot roll back the in-memory write — this is the existing `MemoryVfs` contract,
  not new behaviour.
- A deployment that expects `flush()` to be called automatically must add that
  call; the patch deliberately keeps the runtime free of deployment policy.
- The test observes mounting after a deliberately manifest-less image refuses boot,
  because a complete boot needs the full image and app-boot. It tests the
  construction seam, not tree activation (the preview acceptance covers activation).

## 0002 — An overlay's `home/cordis.patch.yml` merges with the platform rows

### Motivation

The packer writes the platform's required home-patch rows to
`home/cordis.patch.yml` in the base image. A data overlay is applied after the base
image and may itself carry `home/cordis.patch.yml`; because an overlay entry replaces
the base file wholesale, a deployment overlay silently drops the platform rows. Those
rows carry required Worker configuration, so the resulting boot can run with the
wrong platform config instead of failing visibly.

### Behaviour change

`packVfsOverlay` gains an optional second argument:

```ts
export interface PackOverlayOptions {
  readonly platformHomePatch?: readonly PatchOptions[]
}
```

When the overlay being packed carries `home/cordis.patch.yml` and
`platformHomePatch` is non-empty, the packed file is rewritten as the overlay's rows
followed by the platform rows. Loader patch lists apply in order and a later row
replaces an earlier same-id config, so the overlay can add rows or restate one while
the platform's required config still wins. A malformed overlay patch (not a
top-level YAML array of loader patch entries) fails the pack rather than boot.

When `platformHomePatch` is absent or empty, or the overlay carries no home patch,
the overlay bytes are unchanged, including `!!js` expressions. `PackOverlayOptions`
is exported from the package root. Callers that pack an overlay for an image whose
platform rows they know pass them here; callers that do not keep the old signature.

### Tests

`packages/experimental/webworker-packer/tests/overlay-home-patch.spec.ts` packs an
overlay whose `home/cordis.patch.yml` adds one row and restates the platform's
session-persistence row with different compression. It reads the packed file back
through the same YAML schema the packer writes, asserts both the overlay row and the
platform row survive in order, and asserts the platform row is last so its required
config wins.

Run it with:

```sh
pnpm exec vitest run packages/experimental/webworker-packer/tests/overlay-home-patch.spec.ts
```

### Risk

- The default path is byte-identical to today: no overlay home patch, or no
  platform rows supplied, leaves the archive unchanged. Existing callers keep the
  old signature.
- The merge is deliberately one-way: an overlay cannot silently override a
  platform-required row. A deployment that needs different platform config must
  change it where the image is packed, which is the intended ownership.
- `packVfsOverlay` now parses YAML on this path (`js-yaml` and the loader patch
  schema were already dependencies of the packer). The archive remains
  deterministic: the same inputs produce the same bytes.
- This patch does not change `packVfsImage`; an image packed with `homePatch` keeps
  writing that file exactly as before.

## 0003 — WebKit acceptance for the packed Worker deployment

### Motivation

The preview acceptance (`apps/web/tests/preview-boot.e2e.ts`) proves that the packed
Worker image boots the real tree to an interactive page, but it launches headless
Chromium only. The browser deployment's most constrained target is WebKit — the
engine behind WKWebView on iOS — and no browser-runner acceptance exercised that
engine. A WebKit run catches engine-specific boot regressions on the startup chain
before they reach a device.

This draft is **not** a device measurement. iOS and WKWebView behaviour on an iPhone
remains `NOT_VERIFIED` in the phone-DSH documentation until a device run reports
results; the acceptance only runs in Playwright's WebKit build when a runner
provides it.

### Behaviour change

Adds one acceptance case next to the Chromium case in
`preview-boot.e2e.ts`:

- `webkitInstalled()` checks Playwright's `webkit.executablePath()`; the case is
  `it.skipIf(!webkitInstalled())`, so a lane that never installed WebKit reports a
  skip instead of a launch failure.
- The case serves the same built `dist/`, packs (or reuses) the same base image, and
  boots `preview.html?preview-fixture=none` in headless WebKit.
- It holds the boot to the milestones WebKit must carry: the Worker reports the
  tree-active console line with this checkout's lowering contract and zero data
  overlays, the client reaches the first-run workspace surface, and no page error
  fires.
- Chromium-specific response and console expectations stay in the existing
  `bootEmptyPreview` case rather than being asserted against WebKit's different
  resource reporting.

No production code changes.

### Tests

The new case is the test. Run the Chromium and WebKit cases together after building
the preview assets, installing WebKit on a runner that should exercise it:

```sh
pnpm exec playwright install webkit
npm run build
pnpm exec vitest run --config vitest.web.config.ts apps/web/tests/preview-boot.e2e.ts
```

Without the WebKit build the new case skips; the Chromium case is unchanged.

### Risk

- Coverage is opt-in: CI lanes without WebKit get a skip, so the patch cannot fail
  an existing lane. A lane that installs WebKit gains the acceptance.
- WebKit's console and resource reporting differ from Chromium's; the case asserts
  only the boot milestones and uncaught page errors. If WebKit surfaces a
  Chromium-optional resource failure as a page error, it is a real difference to
  investigate rather than a benign skip.
- The case runs only when `dist/` and the base image are available, like the
  existing Chromium case; it does not change the build or packing commands.
- Playwright's WebKit build is a browser-runner approximation, not iOS Safari. A
  pass here does not certify WKWebView, Lockdown mode, JIT, memory or thermal
  behaviour on a phone.
