# Bundle/worker

`Bundle/worker/` is the app's copy of the packed phone-DSH Worker assets. It is
**not committed**: `scripts/copy-bundle-assets.sh` fills the Worker entries from
`plugins/worker-entry/build.mjs` and `plugins/scripts/pack-image.mjs --out <dir>`
(the verified DSH checkout provides the profile and runtime), and preserves the
full DSH Web page built into `web/` by `scripts/ci/build-web-dist.sh`.

The app expects this layout (the same layout `scripts/ci/smoke.sh`
assembles for the macOS smoke test):

```
Bundle/worker/
  index.html
  boot.js
  worker-entry.js        # built entry + the JavaScriptCore compatibility prelude
  tool-worker-python.js  # dedicated CPython tool worker spawned beside the entry
  workflow-isolate.js    # dedicated workflow realm spawned by the Worker workflow bridge
  image.tar.gz
  lazy/<sha256>.tar.gz
  web/index.html         # apps/web/dist, with boot tags injected before the Vite entry
  web/assets/**          # relative Vite chunks, fonts and styles (/static/web/assets/*)
  web/web-boot.js        # built beside worker-entry.js; injected as ./web-boot.js
  web/web-build.json     # actual commit/version, canonical pin, build command, entry path and sha256
  worker.js client.js manifest.json sizes.json probe-bundle.json  # when produced
```

The copy step requires `web/web-build.json` (the real record emitted by
`build-web-dist.sh`) and `sizes.json` from the image packer. Both must name the
same commit and installation version; `probe-bundle.json` records the staged
Web and image sources, including the packer's actual `dsh_checkout`. A missing
or different record fails before `Bundle/worker` is replaced; no record is
synthesized.

The Web page is served at `/static/web/index.html`; its relative `./assets/*`
references therefore resolve to `/static/web/assets/*`, and `web-boot.js`
spawns `/static/worker-entry.js` (`new URL('../worker-entry.js', ...)`). The
legacy `index.html`/`boot.js` page remains at the bundle root for the Worker
smoke and non-Web paths.

Build the page before the copy step when the app should boot the full Web UI
(without it the copy stages the legacy Worker/www assets only):

```bash
# Canonical pin:
bash scripts/ci/build-web-dist.sh --source "$DSH_CHECKOUT" --store /tmp/phone-dsh-pnpm-store
# Controlled checkout (same pair as the upgrade; dsh-pin.json is not edited):
bash scripts/ci/build-web-dist.sh --source "$DSH_CHECKOUT" \
  --commit "$DSH_COMMIT" --version "$DSH_VERSION" --store /tmp/phone-dsh-pnpm-store

examples/probe-app/scripts/copy-bundle-assets.sh --checkout "$DSH_CHECKOUT" --force
```

Until the script runs, this directory contains only `.gitkeep`; the Memory and
Background pages then report the missing files and stay disabled, while the
Probes page keeps working.

See `../README.md` for the exact command sequence.
