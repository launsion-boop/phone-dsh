# Third-party code shipped in the Worker image

`scripts/pack-image.mjs` stages every workspace package under `plugins`
and bundles each package's npm dependencies into its staged `lib/` files
(shared modules land once, in `lib/chunks/`). Everything listed here is
therefore shipped inside the phone image. Each entry is a permissive licence;
the per-package notices (for example `shell-ext/THIRD_PARTY.md`) record the
full installed dependency trees, including packages that are installed but not
bundled.

## npm packages bundled into staged packages

`scripts/pack-image.test.mjs` asserts that this table lists exactly the set of
npm packages the shell-ext staging bundles, so a new bundled dependency fails
the gate until it is recorded here.

| Package | Version | Licence | Source | Bundled through |
| --- | --- | --- | --- | --- |
| `@mixmark-io/domino` | 2.2.0 | BSD-2-Clause | <https://github.com/mixmark-io/domino> | `turndown` (HTML to Markdown DOM) |
| `diff` | 8.0.4 | BSD-3-Clause | <https://github.com/kpdecker/jsdiff> | `just-bash` (`diff` command); installed nested under `node_modules/just-bash/node_modules/diff` |
| `fflate` | 0.8.3 | MIT | <https://github.com/101arrowz/fflate> | bundled through `@phone-dsh/dsh-wasi-toolbox` (git) |
| `just-bash` | 3.6.0 | Apache-2.0 | <https://github.com/vercel-labs/just-bash> | `@phone-dsh/dsh-shell-ext` (`just-bash/browser`) |
| `sprintf-js` | 1.1.3 | BSD-3-Clause | <https://github.com/alexei/sprintf.js> | `just-bash` (`printf` builtin) |
| `turndown` | 7.2.4 | MIT | <https://github.com/mixmark-io/turndown> | `just-bash` (`html-to-markdown` command) |
| `yaml` | 2.9.1 | ISC | <https://github.com/eemeli/yaml> | `@phone-dsh/dsh-feature-admin` (official profile patch writer) |

## Controlled local patch to `just-bash`

`@phone-dsh/dsh-shell-ext` applies one byte-guarded patch to its own installed
`just-bash` 3.6.0 browser bundle (Apache-2.0). The upstream package is not
vendored or forked and its `LICENSE` is retained. The patch exposes the
engine's real terminal execution state to the EXIT-handler consumer
(`shell-ext/src/terminal.ts`).

| Item | Value |
| --- | --- |
| Patched file | `node_modules/just-bash/dist/bundle/browser.js` |
| Pristine SHA-256 | `38f1ad1e3283980ecdf68cede8a4eed028c6dff6e8c31793dec1e0af529c446e` |
| Patched SHA-256 | `124182d76319a5a7c542f4014362f0eba7aa66af9f0a1665574594f0c628e018` |
| Installer | `shell-ext/tools/patch-just-bash.mjs` |
| Provenance | `shell-ext/THIRD_PARTY.md` (Apache-2.0 notice, guards and lifecycle) |

The patch also uses the engine's own full namespace clone/rollback for command
substitution, source/subshell boundaries and every non-`lastpipe` pipeline stage
(so functions, options, `shopt`, cwd, readonly attributes, the terminal cause
and local scopes do not leak into the parent or its EXIT snapshot), snapshots
local array cells, and tags the `trap` command context with a real shell-scope
id (including a stage id composed with nested virtual pids for runtime-resolved
pipeline commands) so child shells cannot clear or replace the root handler. A
typed stage fatal becomes that stage's result instead of ending the root. The
root EXIT handler remains the only one delivered. Producer truncation facts are
forwarded through compound builders and byte-normalised pass-through pipeline
stages, never parsed from marker text. The pristine bundle is only accepted at
exactly
`just-bash` 3.6.0 Apache-2.0; every replacement has an exact count and the
result hash is checked before the atomic write. A fresh `npm ci`,
`npm test`/`npm run typecheck`, the direct image-packer path and
`npm run bundle` all apply or verify it.

## Other components shipped in the image

Non-npm components a workspace package exports into the image (a WebAssembly
build, a data file) are listed here with their licence and the task that added
them. This table is maintained by hand; the staging test does not check it.

| Component | Version | Licence | Source | Shipped by |
| --- | --- | --- | --- | --- |
| `jq.wasm` (first-party `pdsh-jaq-wasm` crate over jaq-core/jaq-std/jaq-json) | jaq-core 3.1.2, jaq-std 3.0.4, jaq-json 2.0.3 | MIT (crate and dependencies) | <https://github.com/01mf02/jaq> | `@phone-dsh/dsh-wasi-toolbox` (`bin/jq`), built by `plugins/wasi-toolbox/jq/build.sh`; not committed |
| `quickjs-emscripten` | 0.32.0 | MIT | <https://github.com/justjake/quickjs-emscripten> | `worker-entry/build.mjs` bundles it into `workflow-isolate.js` (the workflow script's QuickJS/WASM realm) |
| `@jitl/quickjs-wasmfile-release-sync` | 0.32.0 | MIT | <https://github.com/justjake/quickjs-emscripten> | same isolate bundle; release-sync QuickJS/WASM variant loaded from the bundled bytes |
| QuickJS engine | bundled by quickjs-emscripten 0.32.0 | MIT | <https://bellard.org/quickjs/> | compiled WebAssembly inside `@jitl/quickjs-wasmfile-release-sync`, shipped in `workflow-isolate.js` |

## DeepSeek Harness packages

DeepSeek Harness packages (`@deepseek-ai/*`) are not bundled: the packer takes
them from the pinned checkout, and the image carries them as their own
packages under the checkout's licence.
