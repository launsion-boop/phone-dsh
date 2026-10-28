<!-- SPDX-License-Identifier: MIT -->
# Desktop bundle vs. the phone Worker image

`build.mjs` keeps producing the single-file ESM bundle used by the **desktop
simulation** (`dsh-phone.mjs` and `dsh-phone-surface.mjs`). That path targets
the npm `@deepseek-ai/dsh` 0.1.7-rc.2 dependency already installed in
`plugins`, so the existing simulation tests and `sim/` commands continue to
work unchanged.

The **phone path** (DSH 0.2.1-rc.2 in a Web Worker under WKWebView) no longer
uses this bundle. It boots the official `webworker-runtime` from an image built
by `scripts/pack-image.mjs`; see `../scripts/README.md` for the pin check, the
staging step, and the image outputs. Do not add phone-only conditions to
`build.mjs`: the two paths have different runtimes (Node process vs. the
runtime's VFS-backed module layer) and different DSH versions.

Quick reference:

```sh
node bundle/build.mjs                     # desktop simulation bundle
PDSH_DSH_CHECKOUT=<checkout> \
  node scripts/pack-image.mjs --out <dir> # phone Worker image + runtime files
```
